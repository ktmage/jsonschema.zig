FROM alpine:3.21 AS builder

RUN apk add --no-cache curl xz

# Install Zig 0.14.1
RUN curl -L https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz | tar -xJ -C /opt
ENV PATH="/opt/zig-x86_64-linux-0.14.1:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/

RUN zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

FROM alpine:3.21
COPY --from=builder /src/zig-out/bin/bowtie-zig-jsonschema /usr/local/bin/
CMD ["bowtie-zig-jsonschema"]
