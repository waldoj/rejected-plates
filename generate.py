import random
from PIL import Image

def generate_license_plate(text):
    text = text[:8]
    background = Image.open('background.gif').convert('RGBA')
    char_width = 43  # Each character is 43 pixels wide
    spacing = 0  # Spacing between characters

    # Calculate total text width
    text_width = len(text) * char_width

    # Calculate starting x-offset to center the text
    x_offset = (background.width - text_width) // 2
    y_offset = 5  # Vertical offset

    for char in text:
        char_image_file = 'characters/{}.gif'.format(char.lower())
        try:
            char_image = Image.open(char_image_file).convert('RGBA')
            mask = char_image.split()[3]  # Get the alpha band

            background.paste(char_image, (x_offset, y_offset), mask)

            x_offset += char_width + spacing  # Move x-offset for the next character
        except FileNotFoundError:
            print("Character image for '" + char + "' not found.")

    output_file = 'license_plate.png'  # Saving as PNG to preserve transparency
    background.save(output_file)
    print("License plate saved as " + output_file)

def get_random_plate():
    with open('plates.txt', 'r') as file:
        plates = file.readlines()
        # Remove any whitespace characters like `\n` at the end of each line
        plates = [line.strip() for line in plates]
        return random.choice(plates)

# Example usage
random_plate_text = get_random_plate()
print("Random plate selected: " + random_plate_text)
generate_license_plate('DENIED')
