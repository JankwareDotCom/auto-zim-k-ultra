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
      - PUID=1000  # Automatically matches most Linux users
      - PGID=1000  # Automatically matches most Linux users
      - UPDATE_INTERVAL_HOURS=24
      - KEEP_OLD_VERSIONS=1
      - WAIT_FOR_FIRST=1
    restart: unless-stopped
```

**That's it!** The container automatically:
- ✅ Creates a user matching PUID/PGID (defaults to 1000:1000)
- ✅ Fixes all permissions automatically
- ✅ No building required
- ✅ Secure (runs as non-root user)
- ✅ Works on Linux, macOS, and Windows

### If You Get Permission Errors

The default PUID=1000 and PGID=1000 work for most users. If you get permission errors, find your user ID:

```bash
# Find your user ID (Linux/macOS)
id -u  # Your user ID
id -g  # Your group ID
```

Then update your docker-compose.yml:

```yaml
services:
  kiwix:
    environment:
      - PUID=1001  # Use your actual user ID here
      - PGID=1001  # Use your actual group ID here
```

Create an `items.conf` file to specify what content to download(or pass in via an evironment variable)

```
# Format: subdirectory filename_or_prefix
wikipedia wikipedia_en_top
wiktionary wiktionary_en_all
gutenberg gutenberg_en_all
```

Start the container:

```bash
docker-compose up -d
```

### Using Docker Run

```bash
# Create data directory
mkdir -p ./data

# Create items configuration
cat > items.conf << 'EOF'
wikipedia wikipedia_en_top
wiktionary wiktionary_en_all
gutenberg gutenberg_en_all
EOF

# Run container
docker run -d \
  --name kiwix-with-updater \
  -p 8080:8080 \
  -v "$(pwd)/data:/home/app/data" \
  -v "$(pwd)/items.conf:/home/app/data/items.conf" \
  -e PUID=1000 \
  -e PGID=1000 \
  -e UPDATE_INTERVAL_HOURS=24 \
  -e KEEP_OLD_VERSIONS=1 \
  -e WAIT_FOR_FIRST=1 \
  ghcr.io/egiraffe/kiwix-with-updater:latest
```

## Configuration

### Directory Structure

The container uses a conventional home directory structure:

- `/home/app/` - User home directory (owned by user 10001:10001)
- `/home/app/data/` - Application data directory (mounted volume)
- `/home/app/data/zim/` - ZIM files storage
- `/home/app/data/library.xml` - Kiwix library file
- `/home/app/data/items.conf` - Items configuration file

### Permissions

**TL;DR: Just use PUID=1000 and PGID=1000, it works for most people! 🎉**

The container automatically handles permissions:

#### How It Works
- Container starts as root and creates a user with your PUID/PGID
- Fixes all file permissions automatically
- Drops to the created user for security
- No manual permission fixing needed!

#### Default Values (Work for Most People)
```yaml
environment:
  - PUID=1000  # Most Linux users
  - PGID=1000  # Most Linux users
```

#### If You Need Different Values
```bash
# Find your actual user ID (Linux/macOS)
id -u  # Your user ID 
id -g  # Your group ID

# Windows users can usually stick with 1000:1000
```

#### Environment Variables for User Management
- `PUID`: User ID to create inside container (default: 1000)
- `PGID`: Group ID to create inside container (default: 1000)

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEST` | `/home/app/data/zim` | Directory to store ZIM files |
| `LIBRARY` | `/home/app/data/library.xml` | Path to Kiwix library file |
| `ITEMS_PATH` | `/home/app/data/items.conf` | Path to items configuration file |
| `UPDATE_INTERVAL_HOURS` | `24` | How often to check for updates (hours) |
| `KEEP_OLD_VERSIONS` | `0` | Number of old versions to keep per prefix |
| `PORT` | `8080` | Port for Kiwix server |
| `ITEM_DELAY_SECONDS` | `5` | Delay between processing items |
| `HTTP_BASE` | `https://download.kiwix.org/zim` | Base URL for ZIM downloads |
| `WAIT_FOR_FIRST` | `0` | Wait for first ZIM before starting server (1=yes, 0=no) |
| `TMP_MAX_AGE_DAYS` | `14` | Clean up partial downloads older than X days |
| `PRUNE_UNLISTED` | `0` | Remove ZIM files not in items.conf (1=yes, 0=no) |
| `UNLISTED_GRACE_HOURS` | `24` | Grace period before removing unlisted files |
| `UNLISTED_DRY_RUN` | `0` | Dry run mode for unlisted file removal (1=yes, 0=no) |

### Items Configuration

The `items.conf` file specifies what content to download. Each line contains:

```
subdirectory filename_or_prefix
```

Examples:

```
# Exact filenames (for specific versions)
wikipedia wikipedia_en_top_2024-01.zim

# Prefixes (automatically gets latest version)
wikipedia wikipedia_en_top
wiktionary wiktionary_en_all
gutenberg gutenberg_en_all
stack_exchange stackoverflow.com_en_all
ted ted_en

# Comments start with #
# wikipedia wikipedia_en_all  # This line is ignored
```

Available content can be browsed at: https://download.kiwix.org/zim/

## Building from Source

### Build the Docker Image

```bash
# Clone the repository
git clone https://github.com/egiraffe/kiwix-with-updater.git
cd kiwix-with-updater

# Build the image
docker build -t kiwix-with-updater .

# Or build with custom Kiwix base image
docker build --build-arg KIWIX_BASE=ghcr.io/kiwix/kiwix-tools:3.7 -t kiwix-with-updater .
```

### Sample Dockerfile for Custom Builds

```dockerfile
ARG KIWIX_BASE=ghcr.io/kiwix/kiwix-tools:3.7
FROM ${KIWIX_BASE}

# Install required packages
RUN if command -v apk >/dev/null 2>&1; then \
      apk add --no-cache bash rsync coreutils curl ca-certificates; \
    elif command -v apt-get >/dev/null 2>&1; then \
      apt-get update && apt-get install -y --no-install-recommends bash rsync curl ca-certificates && rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" && exit 1; \
    fi

# Copy application files
COPY entrypoint.sh /entrypoint.sh
COPY items.conf /items.conf
RUN chmod +x /entrypoint.sh

# Set default environment variables
ENV DEST=/home/app/data/zim \
    LIBRARY=/home/app/data/library.xml \
    ITEMS_PATH=/home/app/data/items.conf \
    HTTP_BASE=https://download.kiwix.org/zim \
    UPDATE_INTERVAL_HOURS=24 \
    KEEP_OLD_VERSIONS=0 \
    ITEM_DELAY_SECONDS=5 \
    PORT=8080 \
    HOME=/home/app

# Expose volume and port
VOLUME ["/home/app/data"]
EXPOSE 8080

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
```

## Usage Examples

### One-time Download

Run a one-time sync without starting the server:

```bash
docker run --rm \
  -v "$(pwd)/data:/home/app/data" \
  -v "$(pwd)/items.conf:/home/app/data/items.conf" \
  kiwix-with-updater --oneshot
```

### Custom Configuration via Environment

```bash
docker run -d \
  --name kiwix-custom \
  -p 8080:8080 \
  -v "$(pwd)/data:/home/app/data" \
  -e ITEMS="wikipedia wikipedia_en_top
wiktionary wiktionary_en_all
gutenberg gutenberg_en_all" \
  -e UPDATE_INTERVAL_HOURS=12 \
  -e KEEP_OLD_VERSIONS=2 \
  -e PRUNE_UNLISTED=1 \
  kiwix-with-updater
```

### Development Setup

```bash
# Mount the source code for development
docker run -it --rm \
  -p 8080:8080 \
  -v "$(pwd)/data:/home/app/data" \
  -v "$(pwd)/entrypoint.sh:/entrypoint.sh" \
  -v "$(pwd)/items.conf:/home/app/data/items.conf" \
  kiwix-with-updater
```

## Monitoring

### View Logs

```bash
# Follow logs
docker logs -f kiwix-with-updater

# View recent logs
docker logs --tail 100 kiwix-with-updater
```

### Check Status

```bash
# List downloaded ZIM files
docker exec kiwix-with-updater ls -la /home/app/data/zim/

# Check library status
docker exec kiwix-with-updater kiwix-manage /home/app/data/library.xml show
```

## Troubleshooting

### Common Issues

1. **Downloads failing**: Check internet connectivity and verify the subdirectory/filename in `items.conf`
2. **Disk space**: Monitor available space in the mounted volume
3. **Permissions**: Ensure the data directory is writable by the container

### Debug Mode

Set environment variable `DEBUG=1` for verbose logging:

```bash
docker run -e DEBUG=1 ... kiwix-with-updater
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## Acknowledgments

- [Kiwix](https://www.kiwix.org/) for the excellent offline content serving platform
- [OpenZIM](https://openzim.org/) for the ZIM file format and content
