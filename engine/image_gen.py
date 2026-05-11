import os
import requests
import io
import sys
import time
from PIL import Image

def generate_image(prompt, output_path, hf_token):
    # Models to try in order of preference
    models = [
        "stabilityai/stable-diffusion-xl-base-1.0",
        "runwayml/stable-diffusion-v1-5",
        "stabilityai/stable-diffusion-2-1"
    ]
    
    headers = {"Authorization": f"Bearer {hf_token}"}

    for model_id in models:
        api_url = f"https://api-inference.huggingface.co/models/{model_id}"
        print(f"Attempting image generation with model: {model_id}")
        
        try:
            # Hugging Face Inference API often needs a few retries if the model is loading
            for attempt in range(3):
                response = requests.post(api_url, headers=headers, json={"inputs": prompt}, timeout=60)
                
                if response.status_code == 200:
                    image_bytes = response.content
                    try:
                        img = Image.open(io.BytesIO(image_bytes))
                        img.verify()
                        
                        os.makedirs(os.path.dirname(output_path), exist_ok=True)
                        with open(output_path, "wb") as f:
                            f.write(image_bytes)
                        print(f"Successfully generated image using {model_id}")
                        return True
                    except Exception as e:
                        print(f"Model {model_id} returned invalid image data: {e}")
                        break # Try next model
                
                elif response.status_code == 503:
                    # Model is loading, wait and retry
                    wait_time = 20
                    print(f"Model {model_id} is loading. Waiting {wait_time}s... (Attempt {attempt+1}/3)")
                    time.sleep(wait_time)
                    continue
                
                elif response.status_code == 401:
                    print("Error: 401 Unauthorized. The Hugging Face token is invalid.")
                    return False
                
                else:
                    print(f"Model {model_id} failed with status code {response.status_code}: {response.text[:200]}")
                    break # Try next model
                    
        except Exception as e:
            print(f"Error calling {model_id}: {e}")
            continue

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
    
    if len(sys.argv) > 1:
        theme_modifier = sys.argv[1]
        prompt = f"{BASE_PROMPT} Theme: {theme_modifier}"
    else:
        prompt = BASE_PROMPT

    success = generate_image(prompt, OUTPUT_FILE, HF_TOKEN)
    if not success:
        print("All models failed or token is invalid. Image generation skipped.")
        # We don't exit with 1 here to let the rest of the workflow proceed
        sys.exit(0)
