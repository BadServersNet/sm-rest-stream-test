#include <sourcemod>
#include <rest>

#pragma newdecls required
#pragma semicolon 1
#pragma dynamic 786432

public Plugin myinfo =
{
    name = "REST Stream Test",
    description = "Tests the sm-rest streaming HTTP download API",
    author = "BadServers.net",
    version = "0.1.0",
    url = "https://badservers.net"
};

#define DEFAULT_URL "https://ash-speed.hetzner.com/1GB.bin"
#define OUTPUT_PATH "data/rest-stream-test.bin"
#define CHUNK_BUFFER_SIZE 2097152
#define DEFAULT_CHUNK_SIZE 1048576
#define MIN_CHUNK_SIZE 1024
#define PACK_BUFFER_SIZE 524288
#define BYTES_PER_MIB 1048576.0
#define STATUS_INTERVAL 1.0
#define STALL_TIMEOUT_SECONDS 60

enum StreamMode
{
    StreamMode_None = 0,
    StreamMode_Callback,
    StreamMode_File,
};

ConVar g_cvUrl;
ConVar g_cvChunkSize;
ConVar g_cvProgressInterval;
RESTClient g_hClient;
File g_hOutputFile;
Handle g_hStatusTimer;
int g_iRequestId;
StreamMode g_eMode;
int g_iPack[PACK_BUFFER_SIZE];
int g_iBytesReceived;
int g_iContentLength;
int g_iChunkCount;
int g_iLastChunkSize;
int g_iLargestChunkSize;
int g_iProgressUpdates;
float g_fStartTime;
bool g_bCompleted;
int g_iRequesterUserId;
char g_sPhase[64];

public void OnPluginStart()
{
    g_cvUrl = CreateConVar("sm_streamtest_url", DEFAULT_URL, "URL of the test binary to download with the sm-rest streaming API.");
    g_cvChunkSize = CreateConVar("sm_streamtest_chunk_size", "1048576", "Receive buffer size in bytes, which bounds the size of each data callback chunk.", _, true, float(MIN_CHUNK_SIZE), true, float(CHUNK_BUFFER_SIZE));
    g_cvProgressInterval = CreateConVar("sm_streamtest_progress_interval", "100", "Minimum milliseconds between progress callbacks.", _, true, 0.0, true, 10000.0);
    RegAdminCmd("sm_streamtest", Command_StreamTest, ADMFLAG_ROOT, "[url] Streams a test binary to disk through the OnData callback.");
    RegAdminCmd("sm_streamtest_file", Command_StreamTestFile, ADMFLAG_ROOT, "[url] Streams a test binary to disk through SetOutputFile.");
    RegAdminCmd("sm_streamtest_cancel", Command_StreamTestCancel, ADMFLAG_ROOT, "Cancels the running streaming download.");

    g_hClient = new RESTClient();
    g_hClient.Timeout = STALL_TIMEOUT_SECONDS;
    g_hClient.MaxRetries = 0;
}

public void OnPluginEnd()
{
    CleanupDownload();
}

public Action Command_StreamTest(int client, int args)
{
    StartDownload(client, args, StreamMode_Callback);

    return Plugin_Handled;
}

public Action Command_StreamTestFile(int client, int args)
{
    StartDownload(client, args, StreamMode_File);

    return Plugin_Handled;
}

public Action Command_StreamTestCancel(int client, int args)
{
    if (g_iRequestId == 0)
    {
        ReplyToCommand(client, "[StreamTest] No download is running.");
        return Plugin_Handled;
    }

    bool cancelled = g_hClient.Cancel(g_iRequestId);
    ReplyToCommand(client, "[StreamTest] Cancel requested: %s", cancelled ? "ok" : "not found");

    return Plugin_Handled;
}

void StartDownload(int client, int args, StreamMode mode)
{
    if (g_iRequestId != 0)
    {
        ReplyToCommand(client, "[StreamTest] A download is already running. Use sm_streamtest_cancel first.");
        return;
    }

    char url[512];
    ResolveUrl(args, url, sizeof(url));

    char outputPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, outputPath, sizeof(outputPath), OUTPUT_PATH);
    DeleteFile(outputPath);

    if (mode == StreamMode_Callback)
    {
        g_hOutputFile = OpenFile(outputPath, "wb");

        if (g_hOutputFile == null)
        {
            ReplyToCommand(client, "[StreamTest] Failed to open %s for writing.", outputPath);
            return;
        }
    }

    int chunkSize = g_cvChunkSize.IntValue;
    int progressInterval = g_cvProgressInterval.IntValue;

    RESTRequest request = g_hClient.Request(RESTMethod_Get, url);
    request.ChunkSize = chunkSize;
    request.ProgressInterval = progressInterval;
    request.OnHeaders(OnHeadersReceived);
    request.OnProgress(OnProgress);

    if (mode == StreamMode_Callback)
    {
        request.OnData(OnDataReceived);
    }
    else
    {
        char relativePath[PLATFORM_MAX_PATH];
        Format(relativePath, sizeof(relativePath), "addons/sourcemod/%s", OUTPUT_PATH);
        request.SetOutputFile(relativePath, false);
    }

    ResetProgress();
    g_eMode = mode;
    g_iRequestId = request.Send(OnRequestCompleted);

    strcopy(g_sPhase, sizeof(g_sPhase), "Request sent, waiting for headers");
    g_iRequesterUserId = GetRequesterUserId(client);
    g_hStatusTimer = CreateTimer(STATUS_INTERVAL, Timer_ShowStatus, _, TIMER_REPEAT);

    char modeLabel[16];
    ModeLabel(mode, modeLabel, sizeof(modeLabel));
    Report("Streaming download started (%s, chunk size %d, progress interval %dms): %s -> %s (request %d)", modeLabel, chunkSize, progressInterval, url, outputPath, g_iRequestId);
}

void ModeLabel(StreamMode mode, char[] buffer, int maxlength)
{
    if (mode == StreamMode_File)
    {
        strcopy(buffer, maxlength, "output file");
        return;
    }

    strcopy(buffer, maxlength, "data callback");
}

int GetRequesterUserId(int client)
{
    if (client == 0)
    {
        return 0;
    }

    return GetClientUserId(client);
}

void Report(const char[] format, any ...)
{
    char message[512];
    VFormat(message, sizeof(message), format, 2);

    PrintToServer("[StreamTest] %s", message);
    LogMessage("[StreamTest] %s", message);

    int client = GetClientOfUserId(g_iRequesterUserId);

    if (client == 0)
    {
        return;
    }

    PrintToConsole(client, "[StreamTest] %s", message);
}

void ResolveUrl(int args, char[] url, int maxlength)
{
    if (args >= 1)
    {
        GetCmdArg(1, url, maxlength);
        return;
    }

    g_cvUrl.GetString(url, maxlength);
}

void ResetProgress()
{
    g_iBytesReceived = 0;
    g_iContentLength = 0;
    g_iChunkCount = 0;
    g_iLastChunkSize = 0;
    g_iLargestChunkSize = 0;
    g_iProgressUpdates = 0;
    g_fStartTime = GetEngineTime();
    g_bCompleted = false;
}

public Action OnHeadersReceived(RESTClient client, RESTResponse response, any data)
{
    if (g_bCompleted)
    {
        Report("Headers callback arrived after completion. Ignoring.");
        return Plugin_Continue;
    }

    g_iContentLength = response.ContentLength;
    float contentMiB = ToMiB(g_iContentLength);

    strcopy(g_sPhase, sizeof(g_sPhase), "Headers received, streaming body");
    Report("Headers received. HTTP status: %d, Content-Length: %d (%.2f MiB, -1 means chunked or unknown)", response.HttpStatus, g_iContentLength, contentMiB);

    return Plugin_Continue;
}

public void OnProgress(RESTClient client, int downloaded, int downloadTotal, int uploaded, int uploadTotal, any data)
{
    if (g_eMode != StreamMode_File)
    {
        return;
    }

    g_iBytesReceived = downloaded;
    g_iProgressUpdates++;

    if (g_iContentLength <= 0)
    {
        g_iContentLength = downloadTotal;
    }

    strcopy(g_sPhase, sizeof(g_sPhase), "Extension streaming body to disk");
}

public void OnDataReceived(RESTClient client, const char[] chunk, int length, any data)
{
    if (g_bCompleted)
    {
        Report("Data callback arrived after completion (%d bytes). Ignoring.", length);
        return;
    }

    if (g_hOutputFile == null)
    {
        return;
    }

    WriteChunkToFile(chunk, length);

    g_iBytesReceived += length;
    g_iChunkCount++;
    g_iLastChunkSize = length;

    if (length > g_iLargestChunkSize)
    {
        g_iLargestChunkSize = length;
    }

    strcopy(g_sPhase, sizeof(g_sPhase), "Streaming body to disk");
}

void WriteChunkToFile(const char[] chunk, int chunkSize)
{
    if (chunkSize > CHUNK_BUFFER_SIZE)
    {
        LogError("[StreamTest] Chunk of %d bytes exceeds the %d byte buffer. Skipping.", chunkSize, CHUNK_BUFFER_SIZE);
        return;
    }

    int wholeCells = chunkSize / 4;
    int trailingBytes = chunkSize % 4;

    for (int cell = 0; cell < wholeCells; cell++)
    {
        int byteIndex = cell * 4;
        g_iPack[cell] = PackCell(chunk, byteIndex);
    }

    if (wholeCells > 0)
    {
        g_hOutputFile.Write(g_iPack, wholeCells, 4);
    }

    int trailingStart = wholeCells * 4;

    for (int index = 0; index < trailingBytes; index++)
    {
        int byteValue = chunk[trailingStart + index] & 0xFF;
        g_hOutputFile.WriteInt8(byteValue);
    }
}

int PackCell(const char[] chunk, int byteIndex)
{
    int byte0 = chunk[byteIndex] & 0xFF;
    int byte1 = chunk[byteIndex + 1] & 0xFF;
    int byte2 = chunk[byteIndex + 2] & 0xFF;
    int byte3 = chunk[byteIndex + 3] & 0xFF;

    return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24);
}

public void OnRequestCompleted(RESTClient client, RESTResponse response, any data)
{
    float elapsed = GetEngineTime() - g_fStartTime;
    int fileSize = FinishOutputFile();

    g_bCompleted = true;
    g_iRequestId = 0;
    delete g_hStatusTimer;

    if (g_eMode == StreamMode_File)
    {
        g_iBytesReceived = response.BodyLength;
    }

    float receivedMiB = ToMiB(g_iBytesReceived);
    float contentMiB = ToMiB(g_iContentLength);
    float speed = CalculateSpeedMBps(receivedMiB, elapsed);

    char error[256];
    response.GetError(error, sizeof(error));

    if (response.Status != RESTStatus_Ok)
    {
        Report("Download FAILED. status=%d HTTP status: %d, error: %s, received %.2f MiB in %d chunks, time %.1fs", response.Status, response.HttpStatus, error, receivedMiB, g_iChunkCount, elapsed);
        return;
    }

    bool sizeMatches = g_iContentLength <= 0 || g_iContentLength == g_iBytesReceived;
    bool fileMatches = fileSize == g_iBytesReceived;

    char sizeMatchLabel[8];
    YesNo(sizeMatches, sizeMatchLabel, sizeof(sizeMatchLabel));

    char fileMatchLabel[8];
    YesNo(fileMatches, fileMatchLabel, sizeof(fileMatchLabel));

    Report("Download COMPLETE. HTTP status: %d, received %.2f / %.2f MiB in %d chunks (largest %d bytes) with %d progress updates, file on disk %d bytes (match: %s), matches Content-Length: %s, time %.1fs (%.2f MB/s, extension reported %dms)", response.HttpStatus, receivedMiB, contentMiB, g_iChunkCount, g_iLargestChunkSize, g_iProgressUpdates, fileSize, fileMatchLabel, sizeMatchLabel, elapsed, speed, response.ElapsedMs);
}

void YesNo(bool value, char[] buffer, int maxlength)
{
    if (value)
    {
        strcopy(buffer, maxlength, "yes");
        return;
    }

    strcopy(buffer, maxlength, "NO");
}

int FinishOutputFile()
{
    delete g_hOutputFile;

    char outputPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, outputPath, sizeof(outputPath), OUTPUT_PATH);

    int fileSize = FileSize(outputPath);

    return fileSize;
}

public Action Timer_ShowStatus(Handle timer)
{
    if (g_iRequestId == 0)
    {
        g_hStatusTimer = null;
        return Plugin_Stop;
    }

    ShowStatus();

    return Plugin_Continue;
}

void ShowStatus()
{
    if (g_iRequestId == 0 || g_bCompleted)
    {
        return;
    }

    float elapsed = GetEngineTime() - g_fStartTime;
    float receivedMiB = ToMiB(g_iBytesReceived);
    float speed = CalculateSpeedMBps(receivedMiB, elapsed);

    char sizeLine[96];
    FormatSizeLine(receivedMiB, sizeLine, sizeof(sizeLine));

    char message[256];
    Format(message, sizeof(message), "%s | %s | chunks %d (last %d bytes) | progress updates %d | %.1fs (%.2f MB/s)", g_sPhase, sizeLine, g_iChunkCount, g_iLastChunkSize, g_iProgressUpdates, elapsed, speed);

    PrintToServer("[StreamTest] %s", message);

    int client = GetClientOfUserId(g_iRequesterUserId);

    if (client == 0)
    {
        return;
    }

    PrintToConsole(client, "[StreamTest] %s", message);
}

void FormatSizeLine(float receivedMiB, char[] buffer, int maxlength)
{
    if (g_iContentLength <= 0)
    {
        Format(buffer, maxlength, "Received: %.2f MiB", receivedMiB);
        return;
    }

    float contentMiB = ToMiB(g_iContentLength);
    float percent = receivedMiB / contentMiB * 100.0;

    Format(buffer, maxlength, "Received: %.2f / %.2f MiB (%.1f%%)", receivedMiB, contentMiB, percent);
}

float ToMiB(int bytes)
{
    return float(bytes) / BYTES_PER_MIB;
}

float CalculateSpeedMBps(float megabytes, float elapsed)
{
    if (elapsed <= 0.0)
    {
        return 0.0;
    }

    return megabytes / elapsed;
}

void CleanupDownload()
{
    delete g_hStatusTimer;
    delete g_hOutputFile;

    if (g_iRequestId != 0)
    {
        g_hClient.Cancel(g_iRequestId);
        g_iRequestId = 0;
    }
}
