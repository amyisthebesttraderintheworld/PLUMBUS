#!/bin/bash
# Setup script for the trading engine

# Generate private key for cryptographic signatures
openssl genrsa -out private_key.pem 2048

# Create config template
cat > config.json << EOF
{
    "exchanges": ["binance", "coinbasepro", "kraken"],
    "symbols": ["BTC/USDT", "ETH/USDT", "LTC/USDT"],
    "fee_matrix": {
        "binance": 0.001,
        "coinbasepro": 0.005,
        "kraken": 0.0026
    },
    "latency_compensation": 0.002,
    "nvidia_api_key": "your_nvidia_api_key_here",
    "sentiment_api_key": "your_sentiment_api_key_here",
    "telegram_token": "your_telegram_bot_token_here",
    "chat_id": "your_telegram_chat_id_here",
    "private_key_path": "private_key.pem",
    "cycle_interval": 60
}
EOF

echo "Setup complete. Edit engine/config.json with your API keys."