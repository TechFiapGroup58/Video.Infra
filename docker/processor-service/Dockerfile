FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build
WORKDIR /src
COPY src/Video.ProcessorService.Worker/Video.ProcessorService.Worker.csproj .
RUN dotnet restore
COPY src/ .
RUN dotnet publish src/Video.ProcessorService.Worker/Video.ProcessorService.Worker.csproj \
    -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS runtime
# FFmpeg - licenca LGPL/GPL (binario, nao afeta licenca da aplicacao .NET)
RUN apk add --no-cache ffmpeg
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
COPY --from=build /app .
USER appuser
ENTRYPOINT ["dotnet", "Video.ProcessorService.Worker.dll"]
