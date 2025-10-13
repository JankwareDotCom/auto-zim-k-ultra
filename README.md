# Kiwix with Updater

A Docker container that automatically downloads and serves ZIM files using Kiwix, with built-in HTTP-based updating capabilities.

## Features

- 🔄 **Automatic Updates**: Periodically checks for and downloads new ZIM file versions
- 📚 **Library Management**: Automatically manages the Kiwix library with downloaded content
- 🧹 **Cleanup**: Removes old versions and unlisted files to save disk space
- 🌐 **HTTP-only**: Uses HTTP downloads instead of rsync for better compatibility
- ⚡ **Resume Support**: Resumes interrupted downloads automatically
- 🔒 **Verification**: SHA256 checksum verification for downloaded files

## Quick Start

### Zero-Config Setup (Just Works™️)

Create your `docker-compose.yml`:

```yaml
version: '3.8'
services:
  kiwix:
    image: ghcr.io/egiraffe/kiwix-with-updater:latest
    ports:
      - "8080:8080"
    volumes:
      - ./data:/home/app/data
    environment:
      - UPDATE_INTERVAL_HOURS=24
      - KEEP_OLD_VERSIONS=1
      - WAIT_FOR_FIRST=1
    restart: unless-stopped
```

Then run:
```bash
docker-compose up -d
```

**That's it!** The container automatically:
- ✅ Downloads ZIM files based on default configuration
- ✅ Serves them via web interface on http://localhost:8080
- ✅ Updates periodically
- ✅ No manual configuration required

## Configuration

### Items to Download

You can configure what to download in two ways:

#### Option 1: Environment Variable (Simple)
```yaml
services:
  kiwix:
    image: ghcr.io/egiraffe/kiwix-with-updater:latest
    environment:
      ITEMS: |
        wikipedia       wikipedia_en_all_maxi_
        wiktionary      wiktionary_en_all_nopic_
        gutenberg       gutenberg_en_all_
```

#### Option 2: Config File (Advanced)
```yaml
services:
  kiwix:
    image: ghcr.io/egiraffe/kiwix-with-updater:latest
    volumes:
      - ./data:/home/app/data
      - ./items.conf:/home/app/data/items.conf
```

Create `items.conf`:
```
wikipedia       wikipedia_en_all_maxi_
wiktionary      wiktionary_en_all_nopic_
gutenberg       gutenberg_en_all_
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `UPDATE_INTERVAL_HOURS` | `24` | Hours between update checks |
| `KEEP_OLD_VERSIONS` | `0` | Number of old ZIM versions to keep |
| `WAIT_FOR_FIRST` | `0` | Wait for first download before starting server |
| `ITEM_DELAY_SECONDS` | `5` | Delay between processing items |
| `HTTP_BASE` | `https://download.kiwix.org/zim` | Base URL for downloads |
| `PRUNE_UNLISTED` | `0` | Remove files not in items list |
| `UNLISTED_GRACE_HOURS` | `24` | Grace period before removing unlisted files |
| `UNLISTED_DRY_RUN` | `0` | Test mode for unlisted file removal |
| `PORT` | `8080` | Port for web interface |

### Example with Custom Configuration
```yaml
version: '3.8'
services:
  kiwix:
    image: ghcr.io/egiraffe/kiwix-with-updater:latest
    ports:
      - "8080:8080"
    volumes:
      - ./data:/home/app/data
    environment:
      ITEMS: |
        wiktionary      wiktionary_en_all_nopic_
        stack_exchange  gardening.stackexchange.com_en_all_
        wikipedia       wikipedia_en_all_maxi_
        gutenberg       gutenberg_en_all_
        zimit           medlineplus.gov_en_all_
        other           zimgit-post-disaster_en_
      UPDATE_INTERVAL_HOURS: 12
      KEEP_OLD_VERSIONS: 1
      WAIT_FOR_FIRST: 1
      PRUNE_UNLISTED: 1
    restart: unless-stopped
```

## Usage

### Access the Web Interface
Once running, access Kiwix at: http://localhost:8080

### Monitor Logs
```bash
docker-compose logs -f kiwix
```

### Manual Update
```bash
docker-compose exec kiwix /entrypoint.sh update-now
```

## Docker Run (Alternative to docker-compose)

```bash
docker run -d \
  --name kiwix-with-updater \
  -p 8080:8080 \
  -v "$(pwd)/data:/home/app/data" \
  -e UPDATE_INTERVAL_HOURS=24 \
  -e KEEP_OLD_VERSIONS=1 \
  -e WAIT_FOR_FIRST=1 \
  ghcr.io/egiraffe/kiwix-with-updater:latest
```

## Directory Structure

```
./data/                          # Your host data directory
├── zim/                         # Downloaded ZIM files
│   ├── *.zim                   # ZIM files
│   └── .tmp/                   # Temporary download directory
├── library.xml                 # Kiwix library file
└── items.conf                  # Items configuration (if using file method)
```

## Troubleshooting

### Container Won't Start
- Check logs: `docker-compose logs kiwix`
- Verify port 8080 isn't already in use
- Ensure data directory exists

### Downloads Failing
- Check internet connectivity
- Verify ZIM file names in items configuration
- Check available disk space

### Web Interface Not Accessible
- Verify port mapping in docker-compose.yml
- Check firewall settings
- Ensure container is running: `docker-compose ps`

## License

This project is licensed under the GPL3 License - see the [LICENSE](LICENSE) file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## Support

- 📝 [Report issues](https://github.com/yourusername/kiwix-with-updater/issues)
- 💬 [Discussions](https://github.com/yourusername/kiwix-with-updater/discussions)
