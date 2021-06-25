FROM golang:1.16-alpine AS stage

LABEL maintianer="Peng Wenming <ffxgamer@163.com>"

COPY . /go/src 

WORKDIR /go/src

ENV GOPROXY=https://goproxy.io,direct

RUN go get github.com/markbates/pkger/cmd/pkger && \
    pkger -include /scripts && \
    CGO_ENABLED=0 go build \
        -ldflags="-X main.version=0.0.2 -X 'main.buildTime=`date`' -extldflags -static" \
        -o /go/bin/smart-exporter \
        ./cmd/smart-exporter

FROM alpine

COPY --from=stage /go/bin/smart-exporter /usr/bin/


EXPOSE 9111

ENTRYPOINT ["smart-exporter"]
