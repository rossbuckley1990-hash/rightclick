# Development image, not a published or minimized production image.
FROM swift:6.2 AS build
WORKDIR /src
COPY . .
RUN swift build -c release --product rightclick --force-resolved-versions --jobs 2
FROM swift:6.2
RUN useradd --create-home --uid 10001 rightclick
COPY --from=build /src/.build/release/rightclick /usr/local/bin/rightclick
COPY --from=build /src/packaging/ThirdPartyLicenses /usr/local/share/rightclick/licenses
COPY --from=build /src/LICENSE /usr/local/share/rightclick/LICENSE
COPY --from=build /src/Vendor/swift-sdk/LICENSE /usr/local/share/rightclick/licenses/MCP-LICENSE
USER rightclick
WORKDIR /home/rightclick
ENTRYPOINT ["/usr/local/bin/rightclick"]
CMD ["mcp", "--isolated"]

