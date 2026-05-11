import json
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import sys
import os

def generate_visuals(spot_path, perp_path, output_dir):
    try:
        with open(spot_path, 'r') as f:
            spot_data = json.load(f).get('result', [])
        with open(perp_path, 'r') as f:
            perp_data = json.load(f).get('result', [])
    except Exception as e:
        print(f"Error loading data: {e}")
        return

    # 1. Funding Rate Heatmap
    try:
        perp_df = pd.DataFrame(perp_data)
        if not perp_df.empty and 'fundingRateRr' in perp_df.columns:
            # Clean and filter
            perp_df['fundingRate'] = perp_df['fundingRateRr'].astype(float) * 100
            perp_df['symbol'] = perp_df['symbol'].str.replace('^s', '', regex=True)
            
            # Sort and take top/bottom for a readable heatmap
            heatmap_data = perp_df.sort_values('fundingRate', ascending=False)
            top_bottom = pd.concat([heatmap_data.head(10), heatmap_data.tail(10)])
            
            plt.figure(figsize=(12, 8))
            sns.set_theme(style="dark", palette="muted")
            plt.style.use('dark_background')
            
            plot_data = top_bottom[['symbol', 'fundingRate']].set_index('symbol')
            sns.heatmap(plot_data, annot=True, cmap="RdYlGn_r", center=0, fmt=".4f")
            plt.title("PERPETUAL FUNDING RATES (%)", fontsize=15, pad=20)
            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, "funding_heatmap.png"))
            plt.close()
            print("Generated funding_heatmap.png")
    except Exception as e:
        print(f"Error generating funding heatmap: {e}")

    # 2. Top Signal Alpha Chart
    try:
        spot_df = pd.DataFrame(spot_data)
        if not spot_df.empty and 'lastEp' in spot_df.columns and 'openEp' in spot_df.columns:
            spot_df['lastPx'] = spot_df['lastEp'].astype(float) / 100000000
            spot_df['openPx'] = spot_df['openEp'].astype(float) / 100000000
            spot_df = spot_df[spot_df['openPx'] > 0]
            spot_df['changePct'] = ((spot_df['lastPx'] - spot_df['openPx']) / spot_df['openPx']) * 100
            spot_df['symbol'] = spot_df['symbol'].str.replace('^s', '', regex=True)
            
            top_movers = spot_df.sort_values('changePct', ascending=False).head(10)
            
            plt.figure(figsize=(10, 6))
            plt.style.use('dark_background')
            colors = sns.color_palette("viridis", len(top_movers))
            
            bars = plt.barh(top_movers['symbol'], top_movers['changePct'], color=colors)
            plt.xlabel("24h Change (%)", fontsize=12)
            plt.title("TOP MARKET LEADERS (24H)", fontsize=15, pad=20)
            plt.gca().invert_yaxis()
            
            for bar in bars:
                width = bar.get_width()
                plt.text(width, bar.get_y() + bar.get_height()/2, f' {width:.2f}%', 
                         va='center', fontsize=10, color='white')
            
            plt.tight_layout()
            plt.savefig(os.path.join(output_dir, "top_signals.png"))
            plt.close()
            print("Generated top_signals.png")
    except Exception as e:
        print(f"Error generating top signals chart: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python3 visualizer.py <spot_json> <perp_json> <output_dir>")
        sys.exit(1)
    
    generate_visuals(sys.argv[1], sys.argv[2], sys.argv[3])
