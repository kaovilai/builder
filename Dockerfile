ARG UBI_MAJOR=9
FROM registry.access.redhat.com/ubi${UBI_MAJOR}:latest AS bootstrap
# Build-time only: the dnf `go` RPM bootstraps the toolchain build. Its
# RPM payload and dependencies (gcc, openssl-devel, perl, ...) stay out
# of the published image, which installs its own package set.
RUN dnf -y install go jq && \
    dnf clean all

FROM bootstrap AS builder
# GO_VERSION is expected to be in the format of goX.Y.Z ie. go1.20.3
ARG GO_VERSION=
# Set to latest if not set
RUN if [ -z "$GO_VERSION" ] || [ "$GO_VERSION" = "go" ]; then \
    export GO_VERSION=$(curl -q https://go.dev/dl/?mode=json | jq .[0].version | sed 's/\"//g'); \
    fi && \
    echo "GO_VERSION is set to $GO_VERSION" && \
    export GOOS=$(go env GOOS) && \
    export GOARCH=$(go env GOARCH) && \
    export GOPATH=$(go env GOPATH) && \
    rm -rf $GOPATH && \
    rm -f /usr/bin/go && \
    mkdir -p /go && \
    curl -L https://go.dev/dl/$GO_VERSION.$GOOS-$GOARCH.tar.gz -o $GO_VERSION.$GOOS-$GOARCH.tar.gz && \
    tar -C / -xzf $GO_VERSION.$GOOS-$GOARCH.tar.gz && \
    mkdir -p /opt/app-root/src/ && \
    mv /go /opt/app-root/src/go && \
    rm -f $GO_VERSION.$GOOS-$GOARCH.tar.gz && \
    export PATH=$PATH:/opt/app-root/src/go/bin && \
    go env && \
    go version

FROM registry.access.redhat.com/ubi${UBI_MAJOR}:latest AS final
# Consumers compile inside this image: gcc/gcc-c++ keep cgo working
# (CGO_ENABLED defaults to 1). perl arrives as a dependency of git.
RUN dnf -y install git make jq unzip gcc gcc-c++ && \
    dnf clean all
COPY --from=builder /opt/app-root/src/go /opt/app-root/src/go

#This just makes it easier to switch to/from go-toolset.

ENV PATH=$PATH:/opt/app-root/src/go/bin
ENV APP_ROOT /opt/app-root
ENV GOPATH /opt/app-root/src/go
