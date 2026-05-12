import asyncio
import json
import logging
from data_ingestion import DataIngestion
from arbitrage_detector import ArbitrageDetector
from technical_analysis import TechnicalAnalysis
from ai_agents import MultiAgentOptimizer
from telegram_bot import TelegramDelivery
import time

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class TradingEngine:
    def __init__(self, config: Dict):
        self.config = config
        self.data_ingestion = DataIngestion(config['exchanges'], config['symbols'])
        self.arbitrage_detector = ArbitrageDetector(config['fee_matrix'], config['latency_compensation'])
        self.ta = TechnicalAnalysis()
        self.ai_optimizer = MultiAgentOptimizer(config['nvidia_api_key'], config['sentiment_api_key'])
        self.telegram = TelegramDelivery(config['telegram_token'], config['chat_id'], config['private_key_path'])

    async def run_cycle(self):
        """Main trading cycle"""
        logger.info("Starting data ingestion...")
        data = await self.data_ingestion.aggregate_data()

        logger.info("Detecting arbitrage opportunities...")
        spatial = self.arbitrage_detector.detect_spatial_arbitrage(data['tickers'])
        triangular = self.arbitrage_detector.detect_triangular_arbitrage(data['tickers'])
        # Assuming history is available
        history = {}  # Load from file or DB
        statistical = self.arbitrage_detector.detect_statistical_arbitrage(data['tickers'], history)
        opportunities = spatial + triangular + statistical
        filtered_opps = self.arbitrage_detector.filter_opportunities(opportunities)

        for opp in filtered_opps:
            symbol = opp['symbol']
            # Get price history for TA (mock)
            prices = [100 + i*0.1 for i in range(100)]  # mock
            volumes = [1000] * 100

            indicators = self.ta.calculate_indicators(prices, volumes)

            # Combine metrics
            combined_metrics = {
                'arbitrage': opp,
                'indicators': indicators
            }

            # Run AI agents
            orderbooks = [ob for ob in data['orderbooks'] if ob['symbol'] == symbol]
            ai_result = self.ai_optimizer.optimize_signal(combined_metrics, symbol, orderbooks)

            if ai_result['final_decision']:
                signal = {
                    'id': f"{symbol}_{int(time.time())}",
                    **opp,
                    'ai_proposal': ai_result['proposal'],
                    'ai_critique': ai_result['critique']
                }
                # Prepare price data for heatmap
                price_data = {}  # mock heatmap data
                await self.telegram.send_signal(signal, price_data)
                logger.info(f"Signal sent for {symbol}")

    async def run(self):
        """Run the engine continuously"""
        while True:
            try:
                await self.run_cycle()
                await asyncio.sleep(self.config.get('cycle_interval', 60))  # every minute
            except Exception as e:
                logger.error(f"Error in cycle: {e}")
                await asyncio.sleep(10)

# Example config
config = {
    'exchanges': ['binance', 'coinbasepro', 'kraken'],
    'symbols': ['BTC/USDT', 'ETH/USDT', 'LTC/USDT'],
    'fee_matrix': {'binance': 0.001, 'coinbasepro': 0.005, 'kraken': 0.0026},
    'latency_compensation': 0.002,
    'nvidia_api_key': 'your_nvidia_key',
    'sentiment_api_key': 'your_sentiment_key',
    'telegram_token': 'your_bot_token',
    'chat_id': 'your_chat_id',
    'private_key_path': 'private_key.pem',
    'cycle_interval': 60
}

if __name__ == "__main__":
    engine = TradingEngine(config)
    asyncio.run(engine.run())