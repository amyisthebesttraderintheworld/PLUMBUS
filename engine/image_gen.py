import os
import sys
import google.generativeai as genai
import base64

def generate_image(prompt, output_path):
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("Error: GEMINI_API_KEY environment variable not set.")
        return False

    print(f"Generating image using Gemini (gemini-3.1-flash-image) with prompt: {prompt}")
    
    try:
        genai.configure(api_key=api_key)
        model = genai.GenerativeModel("gemini-3.1-flash-image")
        
        response = model.generate_content(prompt)
        
        # Following the user's provided logic for extracting binary data
        # Note: Depending on the SDK version and model, the image might be in inline_data
        try:
            part = response.candidates[0].content.parts[0]
            if hasattr(part, 'inline_data'):
                image_data = part.inline_data.data
            elif hasattr(part, 'text'):
                # Some models might return base64 in text or other fields, 
                # but we'll stick to the user's specific instruction first.
                print("Error: Model returned text instead of image data.")
                return False
            else:
                print("Error: Unexpected response structure from Gemini API.")
                return False
            
            os.makedirs(os.path.dirname(output_path), exist_ok=True)
            with open(output_path, "wb") as f:
                f.write(image_data)
            
            print(f"Successfully saved Gemini-generated image to {output_path}")
            return True
            
        except (AttributeError, IndexError) as e:
            print(f"Error parsing Gemini response: {e}")
            return False

    except Exception as e:
        print(f"Error during Gemini image generation: {str(e)}")
        # Implement backoff or 429 handling is handled by the caller or retries in shell script
        return False

if __name__ == "__main__":
    OUTPUT_FILE = "assets/generated/latest.png"
    
    # Standardized Prompt from previous requirement, adapted for Bauhaus/Geometric as per new instruction
    # The user provided a specific prompt in the snippet: 
    # "Minimalist abstract geometric composition, Bauhaus style, clean lines, flat vector art, suitable for a professional newsletter header."
    
    PROMPT = "Minimalist abstract geometric composition, Bauhaus style, clean lines, flat vector art, suitable for a professional newsletter header."
    
    if len(sys.argv) > 1:
        theme_modifier = sys.argv[1]
        PROMPT = f"{PROMPT} Theme: {theme_modifier}"

    success = generate_image(PROMPT, OUTPUT_FILE)
    if not success:
        print("Gemini image generation failed.")
        sys.exit(0) # Exit 0 to prevent workflow failure as per previous robustness plan
