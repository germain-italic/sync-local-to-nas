# sync-local-to-nas

Rsync synchronization script to NAS.

## Installation

```bash
git clone https://github.com/germain-italic/sync-local-to-nas.git
cd sync-local-to-nas
cp .env.example .env
```

## Configuration

Edit `.env` with your paths and NAS host.

## Usage

```bash
./sync.sh
```

## Behavior

- **One-way sync**: local → NAS only
- **Checksum verification**: compares file checksums, not timestamps
- **No deletion**: existing NAS files are preserved
- **No download**: never downloads files to local
- **Resume support**: partial transfers can be resumed