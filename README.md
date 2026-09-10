# mssql_exporter

把 SQL Server 的查詢結果轉成 Prometheus metrics 的 exporter。你在 `metrics.json` 寫 T-SQL，
它在每次 Prometheus 來抓 `/metrics` 的**當下**才連線執行這些查詢，把結果表的欄位對應成
gauge / counter（可帶 label）後回傳。沒有背景排程、沒有快取：一次 scrape = 一輪查詢。

本 repo 是 [DanielOliver/mssql_exporter](https://github.com/DanielOliver/mssql_exporter) 的 fork
（MIT License，原作者 Daniel Oliver），程式碼與上游 2022-06 的 develop 分支相同。

---

## 環境需求

| 項目 | 實測 |
|---|---|
| 建置 SDK | 專案 TFM 是 `net6.0`，`global.json` 設 `rollForward: latestMajor`，實測 .NET 9.0.309 SDK 可建置（會有 net6.0 已 EOL 的警告） |
| 執行 Runtime | .NET 6 runtime（或用 `--self-contained` 發佈就不需要） |
| 資料庫 | SQL Server，連線帳號要能讀 `sys.sysprocesses`、`sys.dm_os_performance_counters`（預設查詢用到） |
| 網路 | 預設聽 `http://*:80`，Windows 上非管理員通常綁不到 80，改 `-ServerPort` |

> `src/core/core.csproj` 除了 NuGet 的 `System.Data.SqlClient 4.8.3` 之外，還多了一條
> `<Reference>` 指向 `..\..\..\..\..\..\Program Files\dotnet\sdk\NuGetFallbackFolder\...\4.5.1`。
> 這台機器剛好有那個路徑所以建得起來；沒有的機器 MSBuild 會退回用 NuGet 版本。
> 它是可以刪的殘留，見「已知限制」。

## 建置與執行

```powershell
# 建置整個 solution（實測 0 錯誤、6 警告：net6.0 EOL ×2、SqlClient 弱點 ×2 各重複一次）
dotnet build src\mssql_exporter.sln -v minimal

# 直接執行（從 src\server 目錄）
cd src\server
dotnet run -- serve -ServerPort 19345 -DataSource "Server=tcp:127.0.0.1,1433;Initial Catalog=master;Integrated Security=True;Encrypt=False;TrustServerCertificate=True;Connection Timeout=8;"

# 發佈成單一資料夾（CI 用的就是這兩條）
dotnet publish src\server -c Release -o .\out\win   -r win-x64   --self-contained true
dotnet publish src\server -c Release -o .\out\linux -r linux-x64 --self-contained true
```

不帶 `serve` 直接執行只會印出說明後結束。以 Windows 服務身分啟動時會自動走 `serve` 路徑，
不需要在 `binPath` 加參數。

實測（本機 SQL Server、Windows 整合驗證）`http://localhost:19345/metrics` 回傳：

```txt
# HELP mssql_up mssql_up
# TYPE mssql_up gauge
mssql_up 1
# HELP mssql_process_status Counts the number of processes per status
# TYPE mssql_process_status gauge
mssql_process_status{status="suspended"} 1
mssql_process_status{status="background"} 24
mssql_process_status{status="runnable"} 3
mssql_process_status{status="sleeping"} 25
# HELP mssql_process_connections Counts the number of connections per db
# TYPE mssql_process_connections gauge
mssql_process_connections{dbname="master"} 34
mssql_process_connections{dbname="msdb"} 3
# HELP mssql_deadlocks mssql_deadlocks
# TYPE mssql_deadlocks gauge
mssql_deadlocks 0
# HELP mssql_timeouts Number of queries timing out.
# TYPE mssql_timeouts gauge
mssql_timeouts 0
# HELP mssql_exceptions Number of queries throwing exceptions.
# TYPE mssql_exceptions gauge
mssql_exceptions 0
```

DB 連不上時（實測用錯密碼）：`mssql_up 0`、`mssql_exceptions 4`（3 個設定的查詢 + `mssql_up` 自己），
帶 label 的 gauge 只剩 `# HELP/# TYPE` 兩行、沒有樣本；`mssql_deadlocks` 因為設了
`DefaultValue: 0` 會輸出 0。

## 設定

設定來源依序疊加，**後面的蓋掉前面的**：

```
config.json → appsettings.json → 環境變數 PROMETHEUS_MSSQL_* → 命令列 -Xxx
```

兩個 json 檔都是選用的，路徑相對於執行檔所在目錄（不是工作目錄，所以掛成服務也找得到）。
repo 內的 `src/server/config.json` 只放 Serilog 設定。

| 設定 | 命令列 | 環境變數 | 預設 | 說明 |
|---|---|---|---|---|
| DataSource | `-DataSource` | `PROMETHEUS_MSSQL_DataSource` | （無，必填） | .NET SqlClient 連線字串。空值時程式印 `Expected DataSource` 後結束 |
| ConfigFile | `-ConfigFile` | `PROMETHEUS_MSSQL_ConfigFile` | `metrics.json` | 相對路徑會接在執行檔目錄後面 |
| ConfigText | `-ConfigText` | `PROMETHEUS_MSSQL_ConfigText` | （空） | 直接給 metrics JSON 內容；有值時**完全不讀** ConfigFile |
| ServerPath | `-ServerPath` | `PROMETHEUS_MSSQL_ServerPath` | `metrics` | 程式會把所有 `/` 拿掉再前綴一個 `/`，所以 `a/b` 會變成 `/ab` |
| ServerPort | `-ServerPort` | `PROMETHEUS_MSSQL_ServerPort` | `80` | 綁在所有介面 `http://*:port` |
| AddExporterMetrics | `-AddExporterMetrics` | `PROMETHEUS_MSSQL_AddExporterMetrics` | `false` | `true` 時改用 prometheus-net 預設 registry，會多出 .NET runtime 的 `dotnet_*`/`process_*` metrics |
| 日誌等級 | — | `PROMETHEUS_MSSQL_Serilog__MinimumLevel` | `config.json` 裡的 `Information` | 這是 Serilog 設定的 key，實測設 `Warning` 後啟動與 scrape 的 INF 行全部消失 |

`ConfigurationOptions` 上還有 `LogLevel`、`LogFilePath` 兩個屬性，**程式沒有任何地方讀它們**。
repo 根目錄的 `.env` 設了 `PROMETHEUS_MSSQL_LogLevel=Error`，等於沒設。

### metrics.json 格式

```json
{
  "MillisecondTimeout": 4000,
  "Queries": [ { ... }, { ... } ]
}
```

| 欄位 | 說明 |
|---|---|
| `MillisecondTimeout` | 全域逾時，預設 10000。每個查詢實際逾時 = `min(全域, 查詢自己的 MillisecondTimeout)` |
| `Queries[].Name` | 查詢名稱；`Usage` 為 `GaugesWithLabels` / `CountersWithLabels` 時同時是 metric 名稱 |
| `Queries[].Query` | T-SQL，只取第一個結果集 |
| `Queries[].Usage` | 決定三種模式之一，見下表 |
| `Queries[].MillisecondTimeout` | 覆寫此查詢的逾時（只能比全域更短） |
| `Queries[].Columns[]` | 欄位對應 |

三種模式（`Usage` 比對不分大小寫）：

| `Usage` | 行為 | Columns 用法 |
|---|---|---|
| `GaugesWithLabels` | 一個查詢 = 一個帶 label 的 gauge，每一列一組 label | `GaugeLabel` 欄（可多個，`Order` 排序）+ 一個 `Gauge` 欄 |
| `CountersWithLabels` | 同上但是 counter，值只增不減 | `CounterLabel` 欄 + 一個 `Counter` 欄 |
| 省略或其他字串 | 「單列多欄」模式：**只取第一列**，每個欄位各自變成一個獨立 metric | 每個 Column 的 `Label` 是 metric 名、`Usage` 是 `Gauge`/`Counter`、`DefaultValue` 是失敗時回填的值 |

Column 的 `Name` 是 SQL 結果欄名（區分大小寫、比對不到會拋例外），`Label` 在前兩種模式是
Prometheus label 名，在第三種模式是 metric 名。值用 `double.TryParse(ToString())` 轉換，
轉不了的列**靜默跳過**。

### 內建 metrics

| 名稱 | 說明 |
|---|---|
| `mssql_up` | 對 DB 跑 `SELECT 1`，成功 1、失敗 0 |
| `mssql_exceptions` | 本次 scrape 拋例外的查詢數（含 `mssql_up`） |
| `mssql_timeouts` | 本次 scrape 逾時的查詢數 |

## 運作流程

```
Prometheus ──GET /metrics──▶ Kestrel ──▶ prometheus-net MetricServer
                                              │ BeforeCollect callback
                                              ▼
                                   OnDemandCollector.UpdateMetrics()
                                              │ Task.WhenAll（全部查詢同時跑）
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
          IQuery.MeasureWithConnection   ...（每個 metrics.json 查詢）   ConnectionUp (mssql_up)
                    │ 新開 SqlConnection → SqlDataAdapter.Fill → query.Measure(DataSet)
                    │ 與 Task.Delay(timeout) 賽跑，先到者勝
                    ▼
        Success / Timeout / Exception ──▶ 統計進 mssql_timeouts / mssql_exceptions
                                              │
                                              ▼
                                   registry 序列化成文字回給 Prometheus
```

Scrape 是**同步阻塞**的：`UpdateMetrics` 用 `GetAwaiter().GetResult()` 等所有查詢跑完（最多等到
逾時）才回應。實測一個 `WAITFOR DELAY '00:00:05'` 的查詢配 2000 ms 逾時，scrape 剛好 2 秒回來，
`mssql_timeouts 1`，日誌出現 SQL Server 回的 `Operation cancelled by user`，代表查詢在伺服器端也被停掉。

## 專案結構

```
mssql_exporter/
├── metrics.json                 預設的三個查詢（與 src/server/metrics.json 內容相同）
├── Dockerfile                   sdk:6.0 建置 → aspnet:6.0 執行，ENTRYPOINT 帶 serve
├── docker-compose.yml           本地 build + 一個 SQL Server 2017 容器，設定全走環境變數
├── docker-compose-pull.yml      同上但改拉 danieloliver/mssql_exporter:latest
├── .env                         docker-compose 用的變數檔（見已知限制：實際上沒被用到）
├── .github/workflows/
│   ├── dotnetbuild.yaml         ubuntu + windows 各 publish 一份 self-contained，上傳 artifact
│   ├── dockerimage.yaml         每次 push 都 docker build 一次當檢查
│   └── dockerhub.yaml           develop / v* tag / release 時推 Docker Hub（需要 secrets）
└── src/
    ├── global.json              sdk 6.0.0 + rollForward latestMajor
    ├── mssql_exporter.sln
    ├── .run/                    Rider 的執行設定
    ├── core/                    類別庫 mssql_exporter.core
    │   ├── IConfigure.cs        設定介面（DataSource / ConfigFile / ... / LogFilePath）
    │   ├── IQuery.cs            一個查詢的抽象：Name、Query、Timeout、Measure(DataSet)、Clear()
    │   ├── QueryExtensions.cs   MeasureWithConnection：開連線、Fill、逾時取消（CommandTimeout + Cancel）、例外分類；GetColumnIndex
    │   ├── MetricQueryFactory.cs 依 Usage 把 MetricQuery 設定轉成三種 IQuery 之一
    │   ├── CounterExtensions.cs Counter.Set()：只在新值較大時 Inc 差額
    │   ├── config/
    │   │   ├── MetricFile.cs / MetricQuery.cs / MetricQueryColumn.cs   metrics.json 的資料模型
    │   │   ├── Constants.cs     Usage 字串 → enum 的比對（不分大小寫）
    │   │   ├── ColumnUsage.cs / QueryUsage.cs / MeasureResult.cs      enum
    │   │   └── Parser.cs        Newtonsoft 反序列化
    │   ├── queries/
    │   │   ├── GaugeGroupQuery.cs    GaugesWithLabels 實作，記住上輪 label 組合以便移除消失或失敗的序列
    │   │   ├── CounterGroupQuery.cs  CountersWithLabels 實作，同上
    │   │   ├── LabelSetComparer.cs   string[] 逐元素比較，讓 label 組合能當 HashSet 的 key
    │   │   └── GenericQuery.cs       單列多欄模式；GaugeColumn 有 DefaultValue，CounterColumn 沒有
    │   └── metrics/ConnectionUp.cs   mssql_up，就是一個 GenericQuery 跑 SELECT 1
    └── server/                  主控台程式 mssql_exporter
        ├── Program.cs           參數解析、設定疊加、Serilog、建 OnDemandCollector、起 Kestrel
        ├── ConfigurationOptions.cs  IConfigure 的實作與預設值
        ├── OnDemandCollector.cs 註冊 BeforeCollect callback，跑全部查詢並更新統計 gauge
        ├── config.json          Serilog 設定（Console sink、Information）
        └── metrics.json         隨建置輸出複製到 bin，作為預設 ConfigFile
```

## 相依套件

| 套件 | 用途 |
|---|---|
| prometheus-net.AspNetCore 6.0.0 | `UseMetricServer`、`CollectorRegistry`、`MetricFactory`、gauge/counter |
| System.Data.SqlClient 4.8.3 | `SqlConnection` / `SqlDataAdapter`（`QueryExtensions.cs`）。NuGet 對 4.8.3 標了兩個已知弱點 |
| Newtonsoft.Json 13.0.1 | 只在 `Parser.cs` 反序列化 metrics.json |
| Serilog + AspNetCore + Settings.Configuration + Sinks.Console/File + Enrichers.Environment | 日誌；`Sinks.File` 與 `Enrichers.Environment` 有裝但 `config.json` 沒啟用 |
| Microsoft.Extensions.Hosting.WindowsServices 6.0.0 | `IsWindowsService()` 判斷與 `UseWindowsService()` |

## Windows 服務

```cmd
sc create mssql_exporter binPath= "C:\path\to\mssql_exporter.exe"
```

服務模式下程式自動走 `serve`。連線字串與其他設定要用**系統環境變數**或執行檔旁的
`config.json` / `appsettings.json` 給（服務沒有命令列參數可用）。日誌預設只有 Console sink，
掛成服務後看不到；要改 `config.json` 啟用 `Serilog.Sinks.File`。

## Docker（未在本機實測）

`docker-compose.yml` 會 build 本地 Dockerfile 並拉一個 `mssql/server:2017-latest`，兩邊的密碼
都寫在 yml 裡（`yourStrong(!)Password`）。Dockerfile 用 `PublishSingleFile + PublishTrimmed + self-contained`
再放進 `aspnet:6.0` 映像。本次只在 Windows 建置與執行，Docker 路徑僅讀碼確認 CI 有在跑 `docker build`。

## 已知限制

- **單列多欄模式遇到 0 列時**，gauge 回填 `DefaultValue`（沒設就維持上一次的值），counter 不動，不算例外。
  實測 `SELECT 1 WHERE 1=0` 配 `DefaultValue: 5` → 值 5、`mssql_exceptions 0`。
- **帶 label 的查詢失敗或逾時時，該 metric 的所有序列會被移除**，直到下一次成功才重新出現。
  同一查詢前一輪有、這一輪沒有的 label 組合也會被移除。Prometheus 端看到的是序列消失，不是舊值。
- **逾時後的 SQL 端取消最多再等 2 秒。** 逾時會透過 `CommandTimeout` 與 `SqlCommand.Cancel` 送出取消，
  實測 5 秒的查詢配 2000 ms 逾時，2 秒後就收到取消回應。若 SQL Server 2 秒內沒回應取消，
  exporter 會放棄該工作並回報逾時，日誌會多一行 `did not stop within 2000 ms`。
- **每次 scrape 阻塞到最慢的查詢或逾時為止。** Prometheus 的 `scrape_timeout` 要大於 `MillisecondTimeout` 加 2 秒。
- **Counter 只增不減。** SQL Server 重啟後計數器歸零，exporter 的 counter 會停在舊值直到新值超過它。
- **`ConfigurationOptions.LogLevel` / `LogFilePath` 沒作用**，`.env` 裡的 `PROMETHEUS_MSSQL_LogLevel=Error` 也是。
  要調日誌只能用 `PROMETHEUS_MSSQL_Serilog__MinimumLevel` 或改 `config.json`。
- **`.env` 沒被 docker-compose 用到。** 兩個 compose 檔都沒有 `env_file:` 也沒有 `${VAR}` 替換，
  `.env` 只會影響 compose 自己的變數展開，不會進容器。
- **Information 等級會把整份 metrics.json 和每個失敗查詢的完整 stack trace 印進日誌**，
  每次 scrape 都印。正式環境請設 `Warning`。
- **預設連 port 80**，且 `UseUrls` 綁 `*`，沒有任何驗證，任何能連到這台機器的人都能觸發一輪 DB 查詢。
- **`System.Data.SqlClient 4.8.3`** 有 NuGet 標記的中、高嚴重性弱點（GHSA-8g2p-5pqh-5jmc、GHSA-98g6-xh36-x2p7）。
- **net6.0 已於 2024-11 停止支援**，建置時會警告。
- `core.csproj` 那條指到 `NuGetFallbackFolder\...\4.5.1` 的 `<Reference>` 是機器相依的殘留。
- `Dockerfile` 的 `COPY metrics.json ./` 複製到 `/app`，但最後只把 `/app/server/out` 放進 runtime 映像，
  所以那一行沒效果；實際進映像的是 `src/server/metrics.json`（Web SDK 會把 `*.json` 當 Content 複製）。
- `.github/workflows/dockerhub.yaml` 推的是 `danieloliver/mssql_exporter`，需要上游的 Docker Hub secrets，
  在這個 fork 上不會成功。
- 沒有任何自動化測試。
