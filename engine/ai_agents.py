import requests
import json
import logging
from typing import Dict, Any, List
import os

logger = logging.getLogger(__name__)

class SentimentAPI:
    def __init__(self, api_key: str):
        self.api_key = api_key
        self.base_url = "https://api.crypto-sentiment.com"  # example

    def get_sentiment(self, symbol: str) -> Dict[str, Any]:
        try:
            response = requests.get(f"{self.base_url}/sentiment/{symbol}", headers={"Authorization": f"Bearer {self.api_key}"})
            return response.json()
        except Exception as e:
            logger.error(f"Error fetching sentiment: {e}")
            return {"sentiment": "neutral", "score": 0}

class NVIDIAAI:
    def __init__(self, api_key: str, model: str = "meta-llama/Llama-3.3-70B-Instruct", temperature: float = 0.6, max_tokens: int = 4096):
        self.api_key = api_key
        self.model = model
        self.temperature = temperature
        self.max_tokens = max_tokens
        self.url = "https://api.studio.nebius.ai/v1/chat/completions"

    def call_ai(self, prompt: str) -> str:
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        data = {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": self.temperature,
            "max_tokens": self.max_tokens
        }
        try:
            response = requests.post(self.url, headers=headers, json=data, timeout=30)
            response.raise_for_status()
            result = response.json()
            return result['choices'][0]['message']['content']
        except Exception as e:
            logger.error(f"Error calling NVIDIA AI: {e}")
            return "Error: Unable to generate response"

class MultiAgentOptimizer:
    def __init__(self, nvidia_api_key: str, sentiment_api_key: str):
        self.sentiment_api = SentimentAPI(sentiment_api_key)
        self.ai = NVIDIAAI(nvidia_api_key)

    def agent_propose_trade(self, arbitrage_data: Dict, fractal_data: Dict) -> Dict[str, Any]:
        """Agent 1: Propose trade based on data"""
        prompt = f"""
        Based on the following arbitrage opportunities and fractal analysis, propose a trading signal.
        Arbitrage: {json.dumps(arbitrage_data)}
        Fractal: {json.dumps(fractal_data)}
        Propose a trade with entry, exit, and rationale.
        """
        proposal = self.ai.call_ai(prompt)
        return {"proposal": proposal}

    def agent_critique_trade(self, proposal: Dict, symbol: str, orderbook_data: List[Dict]) -> Dict[str, Any]:
        """Agent 2: Critique the proposal using sentiment and order book"""
        sentiment = self.sentiment_api.get_sentiment(symbol)
        # Analyze order book imbalances
        imbalance = self.analyze_orderbook_imbalance(orderbook_data)

        prompt = f"""
        Critique the following trade proposal.
        Proposal: {json.dumps(proposal)}
        Sentiment: {json.dumps(sentiment)}
        Order Book Imbalance: {json.dumps(imbalance)}
        Provide counterarguments and decide if the trade should proceed.
        """
        critique = self.ai.call_ai(prompt)
        return {"critique": critique, "sentiment": sentiment, "imbalance": imbalance}

    def analyze_orderbook_imbalance(self, orderbooks: List[Dict]) -> Dict[str, Any]:
        """Analyze order book for imbalances"""
        total_bid_volume = sum(sum(bid[1] for bid in ob['bids']) for ob in orderbooks)
        total_ask_volume = sum(sum(ask[1] for ask in ob['asks']) for ob in orderbooks)
        imbalance = (total_bid_volume - total_ask_volume) / (total_bid_volume + total_ask_volume) if total_bid_volume + total_ask_volume > 0 else 0
        return {"imbalance_ratio": imbalance, "bid_volume": total_bid_volume, "ask_volume": total_ask_volume}

    def optimize_signal(self, arbitrage_data: Dict, fractal_data: Dict, symbol: str, orderbook_data: List[Dict]) -> Dict[str, Any]:
        """Run the multi-agent loop"""
        proposal = self.agent_propose_trade(arbitrage_data, fractal_data)
        critique = self.agent_critique_trade(proposal, symbol, orderbook_data)

        # Decide based on critique
        # Simple logic: if critique mentions "proceed" or positive, accept
        proceed = "proceed" in critique['critique'].lower() or "valid" in critique['critique'].lower()

        return {
            "proposal": proposal,
            "critique": critique,
            "final_decision": proceed,
            "signal": proposal if proceed else None
        }