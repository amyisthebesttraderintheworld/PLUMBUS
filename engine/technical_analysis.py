import talib
import numpy as np
from typing import Dict, List, Any
import logging

logger = logging.getLogger(__name__)

class TechnicalAnalysis:
    def __init__(self):
        pass

    def calculate_indicators(self, prices: List[float], volumes: List[float]) -> Dict[str, Any]:
        """Calculate basic technical indicators"""
        close = np.array(prices)
        high = np.array(prices)  # assuming OHLC not available, use close
        low = np.array(prices)
        volume = np.array(volumes)

        indicators = {}
        try:
            indicators['rsi'] = talib.RSI(close, timeperiod=14)[-1]
            indicators['macd'], indicators['macdsignal'], indicators['macdhist'] = talib.MACD(close)[-1]
            indicators['bb_upper'], indicators['bb_middle'], indicators['bb_lower'] = talib.BBANDS(close)[-1]
            indicators['sma_20'] = talib.SMA(close, timeperiod=20)[-1]
            indicators['ema_12'] = talib.EMA(close, timeperiod=12)[-1]
        except Exception as e:
            logger.error(f"Error calculating indicators: {e}")
        return indicators

class FractalGeometryFilter:
    def __init__(self, min_period: int = 10, max_period: int = 100):
        self.min_period = min_period
        self.max_period = max_period

    def sierpinski_subdivision(self, data: List[float], level: int = 3) -> float:
        """Recursive geometric subdivision inspired by Sierpinski"""
        if level == 0 or len(data) < 3:
            return np.std(data) / np.mean(data) if np.mean(data) != 0 else 0

        # Divide into three parts
        n = len(data)
        p1 = data[:n//3]
        p2 = data[n//3:2*n//3]
        p3 = data[2*n//3:]

        # Recurse
        s1 = self.sierpinski_subdivision(p1, level-1)
        s2 = self.sierpinski_subdivision(p2, level-1)
        s3 = self.sierpinski_subdivision(p3, level-1)

        # Self-similarity measure: variance of variances
        variances = [s1, s2, s3]
        return np.var(variances)

    def analyze_self_similarity(self, prices: List[float]) -> Dict[str, Any]:
        """Analyze price action self-similarity across timeframes"""
        results = {}
        for period in range(self.min_period, min(self.max_period, len(prices)//3)):
            subset = prices[-period:]
            similarity = self.sierpinski_subdivision(subset)
            results[f'period_{period}'] = similarity

        # Overall self-similarity score
        similarities = list(results.values())
        overall_score = np.mean(similarities) if similarities else 0

        # Trend strength: lower self-similarity might indicate stronger trend
        trend_strength = 1 / (1 + overall_score)  # normalize

        return {
            'self_similarity_scores': results,
            'overall_self_similarity': overall_score,
            'trend_strength': trend_strength,
            'macro_trend_confirmed': trend_strength > 0.7  # arbitrary threshold
        }

    def filter_signal(self, prices: List[float], signal: Dict) -> bool:
        """Filter signal based on fractal analysis"""
        analysis = self.analyze_self_similarity(prices)
        return analysis['macro_trend_confirmed']