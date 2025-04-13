import re

def convert_to_srt_time(timestamp):
    """Convert MM:SS.mmm to HH:MM:SS,mmm"""
    minutes, rest = timestamp.split(':')
    seconds, milliseconds = rest.split('.')
    return f"00:{int(minutes):02}:{int(seconds):02},{int(milliseconds):03}"

def process_square_bracket_subs(input_path, output_path):
    with open(input_path, 'r', encoding='utf-8') as infile:
        lines = infile.readlines()

    srt_entries = []
    counter = 1

    for line in lines:
        match = re.match(r'\[(\d{2}:\d{2}\.\d{3}) --> (\d{2}:\d{2}\.\d{3})\] (.+)', line.strip())
        if match:
            start_time = convert_to_srt_time(match.group(1))
            end_time = convert_to_srt_time(match.group(2))
            text = match.group(3)

            entry = f"{counter}\n{start_time} --> {end_time}\n{text}\n"
            srt_entries.append(entry)
            counter += 1

    with open(output_path, 'w', encoding='utf-8') as outfile:
        outfile.write('\n'.join(srt_entries))

    print(f"✅ Successfully written to: {output_path}")

# === USAGE ===
# Save your subtitle content in "input.txt"
# Then run this:
process_square_bracket_subs("Eng_raw.txt", "Eng_proper.srt")