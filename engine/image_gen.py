import os
import requests
import io
import sys
from PIL import Image

def generate_image(prompt, output_path, hf_token):
    # Using SDXL on Hugging Face Inference API
    API_URL = "https://api-inference.huggingface.co/models/stabilityai/stable-diffusion-xl-base-1.0"
    headers = {"Authorization": f"Bearer {hf_token}"}

    print(f"Generating image with prompt: {prompt}")
    
    try:
        response = requests.post(API_URL, headers=headers, json={"inputs": prompt}, timeout=60)
        
        if response.status_code != 200:
            print(f"Error: API returned status code {response.status_code}")
            print(response.text)
            return False

        image_bytes = response.content
        
        # Validation: check if it's a valid image
        try:
            img = Image.open(io.BytesIO(image_bytes))
            img.verify()
            
            # Save the image
            os.makedirs(os.path.dirname(output_path), exist_ok=True)
            with open(output_path, "wb") as f:
                f.write(image_bytes)
            print(f"Successfully saved generated image to {output_path}")
            return True
        except Exception as e:
            print(f"Error: Generated content is not a valid image: {e}")
            return False

    except Exception as e:
        print(f"Error during image generation: {e}")
        return False

if __name__ == "__main__":
    HF_TOKEN = os.getenv("HF_TOKEN")
    if not HF_TOKEN:
        print("Error: HF_TOKEN environment variable not set.")
        sys.exit(1)

    OUTPUT_FILE = "assets/generated/latest.png"
    
    # Standardized Prompt
    BASE_PROMPT = (
        "Minimalist abstract 3D composition for a financial newsletter background. "
        "Floating frosted glass spheres and soft-edged geometric prisms. "
        "Subtle internal glow in pastel violet, mint, and cyan. "
        "Clean white or light gray void background with strong negative space. "
        "Ultra-clean corporate aesthetic, ray-traced reflections, soft studio lighting, depth of field. "
        "No text, no logos, no symbols."
    )
    
    # Optional theme modifier from command line
    if len(sys.argv) > 1:
        theme_modifier = sys.argv[1]
        prompt = f"{BASE_PROMPT} Theme: {theme_modifier}"
    else:
        prompt = BASE_PROMPT

    success = generate_image(prompt, OUTPUT_FILE, HF_TOKEN)
    if not success:
        sys.exit(1)
