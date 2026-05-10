import numpy as np
from typing import Dict, List, Any, Tuple
import networkx as nx
import logging

logger = logging.getLogger(__name__)

class ArbitrageDetector:
    def __init__(self, fee_matrix: Dict[str, float], latency_compensation: float = 0.001):
        self.fee_matrix = fee_matrix  # exchange -> fee rate
        self.latency_compensation = latency_compensation  # slippage factor

    def calculate_spread(self, ticker1: Dict, ticker2: Dict) -> float:
        """Calculate price spread between two exchanges"""
        price1 = (ticker1['bid'] + ticker1['ask']) / 2
        price2 = (ticker2['bid'] + ticker2['ask']) / 2
        spread = abs(price1 - price2) / min(price1, price2)
        return spread

    def detect_spatial_arbitrage(self, tickers: List[Dict]) -> List[Dict]:
        """Detect cross-exchange arbitrage opportunities"""
        opportunities = []
        symbol_groups = {}
        for ticker in tickers:
            sym = ticker['symbol']
            if sym not in symbol_groups:
                symbol_groups[sym] = []
            symbol_groups[sym].append(ticker)

        for sym, group in symbol_groups.items():
            if len(group) < 2:
                continue
            prices = [(t['exchange'], (t['bid'] + t['ask']) / 2) for t in group]
            prices.sort(key=lambda x: x[1])
            lowest = prices[0]
            highest = prices[-1]
            spread = (highest[1] - lowest[1]) / lowest[1]
            # Account for fees and latency
            effective_spread = spread - self.fee_matrix.get(lowest[0], 0.001) - self.fee_matrix.get(highest[0], 0.001) - self.latency_compensation
            if effective_spread > 0.005:  # 0.5% threshold
                opportunities.append({
                    'type': 'spatial',
                    'symbol': sym,
                    'buy_exchange': lowest[0],
                    'sell_exchange': highest[0],
                    'buy_price': lowest[1],
                    'sell_price': highest[1],
                    'spread': spread,
                    'effective_spread': effective_spread
                })
        return opportunities

    def detect_triangular_arbitrage(self, tickers: List[Dict]) -> List[Dict]:
        """Detect triangular arbitrage within exchange"""
        opportunities = []
        exchange_groups = {}
        for ticker in tickers:
            exch = ticker['exchange']
            if exch not in exchange_groups:
                exchange_groups[exch] = []
            exchange_groups[exch].append(ticker)

        for exch, group in exchange_groups.items():
            # Build graph of currency pairs
            graph = nx.DiGraph()
            currencies = set()
            for t in group:
                base, quote = t['symbol'].split('/')
                currencies.add(base)
                currencies.add(quote)
                # Bid: buy base with quote, rate = bid
                graph.add_edge(quote, base, weight=-np.log(t['bid']))
                # Ask: sell base for quote, rate = 1/ask
                graph.add_edge(base, quote, weight=-np.log(1/t['ask']))

            # Find negative cycles (arbitrage)
            try:
                cycles = nx.negative_edge_cycle(graph)
                if cycles:
                    # Calculate profit
                    profit = 1
                    path = []
                    for i in range(len(cycles)-1):
                        u, v = cycles[i], cycles[i+1]
                        weight = graph[u][v]['weight']
                        profit *= np.exp(-weight)
                        path.append(f"{u}->{v}")
                    profit -= 1  # subtract fees roughly
                    if profit > self.fee_matrix.get(exch, 0.001) + self.latency_compensation:
                        opportunities.append({
                            'type': 'triangular',
                            'exchange': exch,
                            'path': path,
                            'profit': profit
                        })
            except nx.NetworkXError:
                pass  # No cycle
        return opportunities

    def detect_statistical_arbitrage(self, tickers: List[Dict], history: Dict[str, List[float]]) -> List[Dict]:
        """Detect statistical arbitrage based on mean reversion"""
        opportunities = []
        for ticker in tickers:
            sym = ticker['symbol']
            if sym in history:
                prices = history[sym]
                current = (ticker['bid'] + ticker['ask']) / 2
                mean = np.mean(prices)
                std = np.std(prices)
                z_score = (current - mean) / std if std > 0 else 0
                if abs(z_score) > 2:  # 2 sigma
                    opportunities.append({
                        'type': 'statistical',
                        'symbol': sym,
                        'z_score': z_score,
                        'current_price': current,
                        'mean': mean
                    })
        return opportunities

    def filter_opportunities(self, opportunities: List[Dict]) -> List[Dict]:
        """Filter out false positives based on fees and latency"""
        filtered = []
        for opp in opportunities:
            if opp['type'] == 'spatial':
                if opp['effective_spread'] > 0.01:  # 1% min
                    filtered.append(opp)
            elif opp['type'] == 'triangular':
                if opp['profit'] > 0.02:  # 2% min
                    filtered.append(opp)
            elif opp['type'] == 'statistical':
                if abs(opp['z_score']) > 2.5:
                    filtered.append(opp)
        return filtered