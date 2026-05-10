import ccxt
import asyncio
import json
import logging
from typing import Dict, List, Any
import time

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class DataIngestion:
    def __init__(self, exchanges: List[str], symbols: List[str]):
        self.exchanges = {}
        self.symbols = symbols
        for exch_name in exchanges:
            try:
                self.exchanges[exch_name] = getattr(ccxt, exch_name)()
            except AttributeError:
                logger.error(f"Exchange {exch_name} not supported by CCXT")

    async def fetch_orderbook(self, exchange: str, symbol: str) -> Dict[str, Any]:
        exch = self.exchanges.get(exchange)
        if not exch:
            return {}
        try:
            orderbook = await exch.fetch_order_book(symbol)
            return {
                'exchange': exchange,
                'symbol': symbol,
                'bids': orderbook['bids'][:10],  # top 10
                'asks': orderbook['asks'][:10],
                'timestamp': time.time()
            }
        except Exception as e:
            logger.error(f"Error fetching orderbook for {exchange} {symbol}: {e}")
            return {}

    async def fetch_ticker(self, exchange: str, symbol: str) -> Dict[str, Any]:
        exch = self.exchanges.get(exchange)
        if not exch:
            return {}
        try:
            ticker = await exch.fetch_ticker(symbol)
            return {
                'exchange': exchange,
                'symbol': symbol,
                'last': ticker['last'],
                'bid': ticker['bid'],
                'ask': ticker['ask'],
                'volume': ticker['quoteVolume'],
                'timestamp': time.time()
            }
        except Exception as e:
            logger.error(f"Error fetching ticker for {exchange} {symbol}: {e}")
            return {}

    async def aggregate_data(self) -> Dict[str, List[Dict[str, Any]]]:
        tasks = []
        for exch_name in self.exchanges:
            for symbol in self.symbols:
                tasks.append(self.fetch_orderbook(exch_name, symbol))
                tasks.append(self.fetch_ticker(exch_name, symbol))

        results = await asyncio.gather(*tasks, return_exceptions=True)
        data = {'orderbooks': [], 'tickers': []}
        for res in results:
            if isinstance(res, dict) and res:
                if 'bids' in res:
                    data['orderbooks'].append(res)
                else:
                    data['tickers'].append(res)
        return data

# Example usage
if __name__ == "__main__":
    ingestion = DataIngestion(['binance', 'coinbase', 'kraken'], ['BTC/USDT', 'ETH/USDT'])
    data = asyncio.run(ingestion.aggregate_data())
    print(json.dumps(data, indent=2))