import telegram
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
import matplotlib.pyplot as plt
import seaborn as sns
import io
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import serialization
import json
import logging

logger = logging.getLogger(__name__)

class TelegramDelivery:
    def __init__(self, bot_token: str, chat_id: str, private_key_path: str):
        self.bot = telegram.Bot(token=bot_token)
        self.chat_id = chat_id
        with open(private_key_path, "rb") as key_file:
            self.private_key = serialization.load_pem_private_key(key_file.read(), password=None)

    def generate_heatmap(self, price_data: Dict[str, List[float]]) -> io.BytesIO:
        """Generate color-coded heatmap of price discrepancies"""
        plt.figure(figsize=(10, 6))
        sns.heatmap(price_data, annot=True, cmap="RdYlGn", center=0)
        buf = io.BytesIO()
        plt.savefig(buf, format='png')
        buf.seek(0)
        plt.close()
        return buf

    def create_inline_buttons(self, signal: Dict) -> InlineKeyboardMarkup:
        """Create interactive inline scenario buttons"""
        keyboard = [
            [InlineKeyboardButton("View Entry Conditions", callback_data=f"entry_{signal['id']}")],
            [InlineKeyboardButton("View Exit Scenarios", callback_data=f"exit_{signal['id']}")],
            [InlineKeyboardButton("Risk Assessment", callback_data=f"risk_{signal['id']}")]
        ]
        return InlineKeyboardMarkup(keyboard)

    def generate_natural_language_summary(self, signal: Dict) -> str:
        """Generate natural language summary"""
        if signal['type'] == 'spatial':
            summary = f"Spatial arbitrage opportunity detected for {signal['symbol']}. Buy on {signal['buy_exchange']} at {signal['buy_price']:.2f}, sell on {signal['sell_exchange']} at {signal['sell_price']:.2f}. Expected spread: {signal['effective_spread']:.2%}."
        elif signal['type'] == 'triangular':
            summary = f"Triangular arbitrage on {signal['exchange']}: {' -> '.join(signal['path'])}. Potential profit: {signal['profit']:.2%}."
        else:
            summary = f"Statistical arbitrage for {signal['symbol']}. Z-score: {signal['z_score']:.2f}."
        return summary

    def sign_message(self, message: str) -> str:
        """Create cryptographic signature"""
        signature = self.private_key.sign(
            message.encode(),
            padding.PSS(
                mgf=padding.MGF1(hashes.SHA256()),
                salt_length=padding.PSS.MAX_LENGTH
            ),
            hashes.SHA256()
        )
        return signature.hex()

    async def send_signal(self, signal: Dict, price_data: Dict = None):
        """Broadcast verified signal"""
        summary = self.generate_natural_language_summary(signal)
        message = f"🚀 **Trading Signal Alert**\n\n{summary}\n\nAudit Log ID: {signal.get('id', 'N/A')}"

        # Sign the message
        signature = self.sign_message(message)
        message += f"\n\nSignature: {signature}"

        # Send text
        await self.bot.send_message(chat_id=self.chat_id, text=message, parse_mode='Markdown')

        # Send heatmap if available
        if price_data:
            heatmap = self.generate_heatmap(price_data)
            await self.bot.send_photo(chat_id=self.chat_id, photo=heatmap, caption="Price Discrepancy Heatmap")

        # Send inline buttons
        reply_markup = self.create_inline_buttons(signal)
        await self.bot.send_message(chat_id=self.chat_id, text="Interactive Options:", reply_markup=reply_markup)

# Example usage
if __name__ == "__main__":
    # This would be run in an async context
    pass