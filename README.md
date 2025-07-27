# sync-local-to-nas

Rsync synchronization script to NAS.

## Installation

```bash
git clone https://github.com/germain-italic/sync-local-to-nas.git
cd sync-local-to-nas
cp .env.example .env
```

## Configuration

Edit `.env` with your paths and NAS host:

- `SOURCE_X`: Source folders to sync (numbered: SOURCE_1, SOURCE_2, etc.)
- `NAS_HOST`: Target NAS (user@hostname)
- `DESTINATION`: Destination path on NAS
- `USE_CHECKSUM`: Use checksums for verification (true/false)
- `MAX_ATTEMPTS`: Retry attempts on failure

## Usage

```bash
./sync.sh
```

## Behavior

- **One-way sync**: local → NAS only
- **Configurable verification**: checksums (slower, reliable) or date/size (faster)
- **No deletion**: existing NAS files are preserved
- **No download**: never downloads files to local
- **Resume support**: partial transfers can be resumed
- **Retry mechanism**: exponential backoff on failures
- **Detailed logging**: progress, stats, and itemized changes