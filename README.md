# PLUMBUS Quick Reference Guide

PLUMBUS (Price Level Updates, Market Briefings, & Universal Signals) is a crypto trading bot that analyzes market data, generates trading signals, and sends automated briefings via Telegram.

## Project Structure

- `run.sh` - Main entry point script
- `scripts/` - Core bot scripts (plumbus.sh, sentry.sh, utilities)
- `data/` - Trade state and history data
- `tests/` - Integration tests and mock data
- `docs/` - Documentation and development plans
- `deploy/` - Deployment automation scripts

## Running the Trading Bot
```bash
./run.sh
```

## Monitoring & Operations

### Health Check
```bash
bash scripts/health_monitor.sh
```
Generates a health report showing:
- Bot heartbeat status
- Error rate analysis
- Trade activity metrics
- Loss streak detection

### Log Rotation
```bash
# Manual rotation check
bash scripts/log_rotation.sh rotate

# View log statistics
bash scripts/log_rotation.sh stats

# Clean up old backups
bash scripts/log_rotation.sh cleanup
```

### Running Tests
```bash
# Run all integration tests
bash tests/test_integration.sh
```

## Configuration

### Test Environment
Source `.env.test` for testing with mock credentials:
```bash
source .env.test
```

### Production Logging
The bot logs to `./plumbus.log` with structured entries:
- Timestamps: `YYYY-MM-DD HH:MM:SS`
- Log levels: `[INFO]`, `[WARN]`, `[ERROR]`
- All API calls, retries, and errors logged

### API Timeouts (in market_brief.sh)
```bash
API_TIMEOUT=15          # Phemex API timeout (seconds)
NVIDIA_TIMEOUT=30       # AI model API timeout (seconds)  
TELEGRAM_TIMEOUT=10     # Telegram API timeout (seconds)
```

## Error Handling

### API Failures
The bot automatically retries failed API calls with exponential backoff:
- Timeout detection and specific error messages
- Up to 3 retries (configurable via `RETRY_MAX`)
- Detailed logging of all failures

### Log Monitoring
Check for errors or warnings:
```bash
grep "\[ERROR\]" plumbus.log
grep "\[WARN\]" plumbus.log
```

## File Structure
```
PLUMBUS/
├── market_brief.sh           # Main trading bot (enhanced)
├── run_plumbus.sh            # Wrapper with logging
├── sentry_plumbus.sh         # 15-minute heartbeat monitor
├── deploy_oci.sh             # Oracle Cloud deployment
├── trade_state.json          # Current trade state
├── trade_history.json        # Historical trades
├── plumbus.log              # Application logs (auto-rotated)
├── IMPLEMENTATION_SUMMARY.md # Development work details
├── .env.test                # Test configuration
├── scripts/
│   ├── log_rotation.sh      # Log management utility
│   └── health_monitor.sh    # Health monitoring
└── tests/
    ├── test_helpers.sh      # Test framework
    ├── test_integration.sh  # Integration test suite
    ├── mock_spot_data.json  # Mock market data
    └── mock_perp_data.json  # Mock perpetual data
```

## Troubleshooting

### Bot not running?
1. Check health: `bash scripts/health_monitor.sh`
2. Review logs: `tail -20 plumbus.log`
3. Verify heartbeat: `ls -la .plumbus_heartbeat`

### API timeouts?
- Increase timeout values in market_brief.sh
- Check network connectivity
- Verify API keys in .env

### Test failures?
```bash
bash -x tests/test_integration.sh  # Run with debug output
```

## Next Phase Goals

Phase 2: Risk Management & Safety
- [ ] Dynamic position sizing
- [ ] Maximum drawdown limits
- [ ] Exposure limits per asset
- [ ] Emergency stop mechanism
- [ ] Enhanced performance tracking

See `development_plan.txt` for full roadmap.
