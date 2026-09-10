FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /app

# copy csproj and restore as distinct layers
COPY src/core/*.csproj ./core/
COPY src/server/*.csproj ./server/
WORKDIR /app/core
RUN dotnet restore -r linux-x64
WORKDIR /app/server
RUN dotnet restore -r linux-x64

# copy and build app and libraries
WORKDIR /app
COPY src/core/. ./core/
COPY src/server/. ./server/
WORKDIR /app/server
# Self-contained single file. No PublishTrimmed: since .NET 7 trimming defaults to "full" and
# would strip the reflection-loaded types Newtonsoft (metrics.json) and Serilog.Settings.Configuration need.
RUN dotnet publish -c Release -r linux-x64 --no-restore -o out -p:PublishSingleFile=true --self-contained true

# Self-contained output only needs the native prerequisites, not the ASP.NET Core runtime image.
FROM mcr.microsoft.com/dotnet/runtime-deps:8.0 AS runtime
EXPOSE 80
WORKDIR /app
COPY --from=build /app/server/out ./
ENTRYPOINT ["./mssql_exporter", "serve"]
