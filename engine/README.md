# PLUMBUS Trading Engine

A comprehensive, modular trading signal and arbitrage detection engine.

## Architecture

### Data Ingestion Layer
- Uses CCXT for real-time order books, tickers, and volume data across multiple exchanges.
- Asynchronous data fetching for low latency.

### Arbitrage Detection
- **Spatial Arbitrage**: Cross-exchange price discrepancies.
- **Triangular Arbitrage**: Within-exchange currency cycles.
- **Statistical Arbitrage**: Mean-reversion opportunities.
- Includes fee calculation matrix and latency compensation to filter false positives.

### Technical Analysis Pipeline
- Basic indicators via TA-Lib (RSI, MACD, Bollinger Bands, etc.).
- Custom Fractal Geometry Filter using recursive Sierpinski-style subdivision for self-similarity analysis across timeframes.

### Multi-Agent AI Optimization
- Agent 1: Proposes trades based on arbitrage and fractal metrics.
- Agent 2: Critiques proposals using sentiment APIs, order book imbalances, and news velocity.
- Devil's Advocate loop to validate signals.

### Telegram Delivery Layer
- Adaptive UI with color-coded heatmaps of price discrepancies.
- Interactive inline buttons for entry/exit conditions.
- Natural language summaries.
- Cryptographic signatures for audit transparency.

## Setup

1. Install dependencies: `pip install -r requirements.txt`
2. Run setup: `bash setup.sh`
3. Edit `config.json` with your API keys.
4. Run: `python main.py`

## Configuration

- `exchanges`: List of CCXT-supported exchanges.
- `symbols`: Trading pairs to monitor.
- `fee_matrix`: Trading fees per exchange.
- `latency_compensation`: Slippage factor.
- API keys for NVIDIA AI, sentiment API, Telegram.

## Security

- All signals include cryptographic signatures linked to performance audit logs.
- Private key generated during setup for signing.

## Disclaimer

This is for educational purposes. Trading involves risk. Use at your own discretion.