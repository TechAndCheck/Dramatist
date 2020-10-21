#!/usr/bin/env ruby

require "rubygems"
require "bundler/setup"
require "securerandom"
require "open3"
require "csv"
Bundler.require(:default)
# all require_all entries have to be after this, so the gem is loaded properly first
require "google/cloud/storage"

program :name, "Dramatist"
program :version, "0.0.1"
program :description, "Transcribe a YouTube stream using Google's Speech to Text"

command :transcribe do |c|
  c.syntax = "dramatist transcribe <youtube_url> [options]"
  c.summary = ""
  c.description = ""
  c.example "Run the refinery", "transcribe <youtube_url>"
  c.action do |args, options|
    url = args[0]

    if url.nil?
      puts "Error: No YouTube video url passed in."
      exit
    end

    Dir.mkdir "tmp" unless Dir.exist?("tmp")

    file_name = "tmp/#{SecureRandom.uuid}"

    spinner = TTY::Spinner.new("[:spinner] Downloading video file ...", format: "spin_2")
    spinner.auto_spin

    options = {
      "extract-audio": true,
      "audio-format": "wav",
      "audio-quality": "0",
      output: "#{file_name}.%(ext)s"
    }

    YoutubeDL.download url, options
    spinner.success("Done!")

    spinner = TTY::Spinner.new("[:spinner] Mixing down ...", format: "spin_2")
    spinner.auto_spin
    ffmpeg_call = "ffmpeg -i #{file_name}.wav -ac 1 #{file_name}-mono.wav"
    Open3.popen3(ffmpeg_call) do |stdin, stdout, stderr, wait_thr|
      stdout.read
    end
    spinner.success("Done mixing it all up!")

    spinner = TTY::Spinner.new("[:spinner] Uploading to GCS ...", format: "spin_2")
    spinner.auto_spin

    gcs_path = upload_file("#{file_name}-mono.wav", "#{file_name}.wav")
    spinner.success("It's there now!")

    speech = Google::Cloud::Speech.speech

    config     = { encoding:          :LINEAR16,
                   sample_rate_hertz: 48_000,
                   language_code:     "en-US",
                   use_enhanced:       true,
                   model:             "video",
                   max_alternatives:  1,
                   enable_automatic_punctuation: true,
                   profanity_filter: false,
                   diarization_config: {
                      enable_speaker_diarization: true,
                      min_speaker_count: 3,
                      max_speaker_count: 3
                    }
                  }

    spinner = TTY::Spinner.new("[:spinner] Transcribing ...", format: "spin_2")
    spinner.auto_spin

    audio = { uri: gcs_path }
    operation = speech.long_running_recognize config: config, audio: audio

    # puts "Operation started"

    operation.wait_until_done!
    spinner.success("Complete!")

    raise operation.results.message if operation.error?

    results = operation.response.results
    transcripts = results.map do |result|
      result.alternatives.first.words
    end

    spinner = TTY::Spinner.new("[:spinner] Saving transcription to file ...", format: "spin_2")
    # spinner.auto_spin
    File.open("results.html", "w") do |f|
      f.puts "<html><body>"
      transcripts.each do |t|
        current_speaker_id = nil

        entry = t.map do |x|
          response = span_tags(current_speaker_id, x.speaker_tag)
          current_speaker_id = x.speaker_tag

          "#{response}#{x.word}"
        end

        # Make sure the whole thing ends with a span tag
        entry << "</span>"

        f.puts(entry.join(" "))
      end
      f.puts "</html></body>"
    end
    spinner.success("Saved!")
  end

  def upload_file(path, file_name)
    storage = Google::Cloud::Storage.new
    bucket = storage.bucket "dramatist"
    bucket.create_file path,
                                  file_name
    "gs://dramatist/#{file_name}"
  end

  def span_tags(speaker_id_1, speaker_id_2)
    if speaker_id_2 != speaker_id_1
      # Close off the previous span (if there is one)
      response = speaker_id_1.nil? ? "" : "</span>"
      # Start formatting the next on
      response + span_tab_for_speaker_id(speaker_id_2)
    end
  end

  def span_tab_for_speaker_id(id)
    color = css_color_for_speaker_id(id)
    "<span style=\"background-color:#{color}\">"
  end

  def css_color_for_speaker_id(id)
    # Initialize the speakers hash if it doesn't exist yet
    @speakers ||= {}
    # Get the right color, or create a new one
    @speakers[id] ||= Random.bytes(3).unpack1("H*")
    # Return the CSS Value
    "##{@speakers[id]}"
  end
end

default_command :transcribe
