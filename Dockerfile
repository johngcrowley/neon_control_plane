# Use the official Rust image as a parent image
FROM rust:latest AS builder

# Install required system dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy the Cargo.toml and Cargo.lock files
COPY Cargo.toml Cargo.lock ./

# Copy the source code
COPY src/ ./src/

# Build the application in release mode
RUN cargo build --release

# Use a minimal runtime image
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user
RUN useradd -r -s /bin/false neon

# Copy the binary from the builder stage
COPY --from=builder /app/target/release/neon_control_plane /usr/local/bin/control_plane

# Change ownership to the non-root user
RUN chown neon:neon /usr/local/bin/control_plane

# Switch to the non-root user
USER neon

# Expose the port
EXPOSE 3000

# Run the binary
CMD ["/usr/local/bin/control_plane"]
