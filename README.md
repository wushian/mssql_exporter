# mssql_exporter

把 SQL Server 的查詢結果轉成 Prometheus metrics 的 exporter。你在 `metrics.json` 寫 T-SQL，
它在每次 Prometheus 來抓 `/metrics` 的**當下**才連線執行這些查詢，把結果表的欄位對應成
gauge / counter（可帶 label）後回傳。沒有背景排程、沒有快取：一次 scrape = 一輪查詢。

本 repo 是 [DanielOliver/mssql_exporter](https://github.com/DanielOliver/mssql_exporter) 的 fork
（MIT License，原作者 Daniel Oliver）。以上游 2022-06 的 develop 為基礎，之後的修正與升級見 git log。

---

## 環境需求

| 項目 | 實測 |
|---|---|
| 建置 SDK | 專案 TFM 是 `net8.0`，`global.json` 設 8.0.100 起 `rollForward: latestMajor`，實測 .NET 9.0.309 SDK 可建置，0 警告 |
| 執行 Runtime | ASP.NET Core 8.0 Runtime（或用 `--self-contained` 發佈就不需要） |
| 資料庫 | SQL Server，連線帳號要能讀 `sys.sysprocesses`、`sys.dm_os_performance_counters`（預設查詢用到） |
| 網路 | 預設聽 `http://*:80`，Windows 上非管理員通常綁不到 80，改 `-ServerPort` |

> 資料庫驅動是 `Microsoft.Data.SqlClient`，和舊版 `System.Data.SqlClient` 有兩個行為差異，
> 換版時連線字串要檢查，見「已知限制」的前兩條。

## 建置與執行

```powershell
# 建置整個 solution（實測 0 錯誤、0 警告）
dotnet build src\mssql_exporter.sln -v minimal

# 直接執行（從 src\server 目錄）
cd src\server
dotnet run -- serve -ServerPort 19345 -DataSource "Server=tcp:localhost,1433;Initial Catalog=master;Integrated Security=True;Encrypt=False;TrustServerCertificate=True;Connection Timeout=8;"

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
├── Dockerfile                   sdk:8.0 建置 self-contained 單檔 → runtime-deps:8.0 執行，ENTRYPOINT 帶 serve
├── docker-compose.yml           本地 build + 一個 SQL Server 2017 容器，設定全走環境變數
├── docker-compose-pull.yml      同上但改拉 danieloliver/mssql_exporter:latest
├── .env                         docker-compose 用的變數檔（見已知限制：實際上沒被用到）
├── deploy/
│   ├── mssql_exporter/run-mssql_exporter.cmd   Release zip 內的啟動腳本，首次啟動複製 example 設定檔
│   └── sql_exporter/            搭配用的 sql_exporter 設定、啟動與建置腳本（見下方章節）
├── .github/workflows/
│   ├── release.yaml             推 v* tag → windows runner 建置 portable 包 → 建立 Release；dispatch 只出 artifact
│   ├── dotnetbuild.yaml         ubuntu + windows 各 publish 一份 self-contained，上傳 artifact
│   ├── dockerimage.yaml         每次 push 都 docker build 一次當檢查
│   └── dockerhub.yaml           每次 push 都 build image；只有設了 DOCKERHUB_USERNAME/TOKEN secrets 才推 Docker Hub
└── src/
    ├── global.json              sdk 8.0.100 + rollForward latestMajor
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
    │   │   ├── LabelledGroupQuery.cs 帶 label 查詢的共用邏輯：欄位對應、記住上輪 label 組合、移除消失或失敗的序列
    │   │   ├── GaugeGroupQuery.cs    GaugesWithLabels：把值送進 Gauge
    │   │   ├── CounterGroupQuery.cs  CountersWithLabels：把值送進 Counter
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
| Microsoft.Data.SqlClient 7.0.2 | `SqlConnection` / `SqlDataAdapter` / `SqlCommand.Cancel`（`QueryExtensions.cs`） |
| Newtonsoft.Json 13.0.4 | 只在 `Parser.cs` 反序列化 metrics.json |
| Serilog + AspNetCore + Settings.Configuration + Sinks.Console/File + Enrichers.Environment | 日誌；`Sinks.File` 與 `Enrichers.Environment` 有裝但 `config.json` 沒啟用 |
| Microsoft.Extensions.Hosting.WindowsServices 8.0.1 | `IsWindowsService()` 判斷與 `UseWindowsService()` |

## 從 GitHub Release 佈署（Windows）

推 `v*` tag 會由 `.github/workflows/release.yaml` 在 windows runner 建置並建立 Release，
附件是 `mssql_exporter-<版本>-portable-win-x64.zip`。這是 **framework-dependent** 包，
伺服器要先裝 **ASP.NET Core 8.0 Runtime**（不是只有 .NET Runtime）。

zip 內容：

| 項目 | 說明 |
|---|---|
| `mssql_exporter.exe` 與 dll | 版本號從 tag 注入，`(Get-Item mssql_exporter.dll).VersionInfo.ProductVersion` 可查 |
| `config.json.example`、`metrics.json.example` | **真檔不在 zip 裡**。升級時直接解壓覆蓋，現場改過的 `metrics.json` 不會被重設 |
| `run-mssql_exporter.cmd` | 首次啟動時把兩個 example 複製成真檔，然後 `serve`。掛服務用 nssm 指到這個 cmd |
| `sql_exporter/` | 搭配用的 sql_exporter 設定與建置腳本，見上一節；exe 要另外建 |

連線字串用**系統環境變數** `PROMETHEUS_MSSQL_DataSource` 給，或在 exe 旁放
`appsettings.json` 寫 `{"DataSource": "..."}`（服務沒有命令列參數可用）。
日誌預設只有 Console sink，掛成服務後看不到；要改 `config.json` 啟用 `Serilog.Sinks.File`。

不用 nssm 的話也可以直接：

```cmd
sc create mssql_exporter binPath= "C:\path\to\mssql_exporter.exe"
```

服務模式下程式自動走 `serve`，但這樣首次啟動不會自動產生 `metrics.json`，要先手動從 example 複製。

手動觸發（Actions 頁面的 Run workflow）只會產出 workflow artifact，不建 Release，適合改過 workflow 後先試跑。

## 搭配 sql_exporter 跑重查詢

本專案每次 scrape 都即時查 DB，適合輕量、要新鮮的 DMV。幾分鐘跑一次就好的重查詢
（資料庫大小、wait stats、效能計數器）交給 [justwatchcom/sql_exporter](https://github.com/justwatchcom/sql_exporter)
在背景排程執行，兩個 exporter 並行，互不影響。`deploy/sql_exporter/` 放的是可直接用的一套：

| 檔案 | 說明 |
|---|---|
| `build-sql_exporter.ps1` | 上游沒發佈二進位檔，此腳本抓獨立 Go 工具鏈、clone v0.8、建出 `sql_exporter.exe`（實測 go1.27.1，產出約 60 MB，exe 不進版控） |
| `config.yml` | 四個 MS SQL 查詢：各庫 data/log 大小、五個效能計數器、前 20 名 wait 類型、目前被封鎖的請求數。每分鐘跑一次 |
| `run-sql_exporter.cmd` | 啟動，預設聽 9237。掛服務用 nssm 指到這個 cmd 即可 |
| `prometheus-scrape.yml` | 兩個 exporter 的 scrape 片段 |

連線字串不給帳號就走 Windows 整合驗證，實測本機 `sqlserver://127.0.0.1:1433?database=master&encrypt=disable` 直接可用。
metric 一律叫 `sql_<name>`，並自動附 `driver`、`host`、`database`、`user`、`col`、`sql_job` 六個 label；
一個查詢多個 `values` 欄時靠 `col` 區分。實測輸出節錄：

```txt
sql_mssql_db_size_mb{col="size_mb",dbname="DBA",filetype="data",host="127.0.0.1:1433",sql_job="mssql_heavy"} 1739.0625
sql_mssql_db_size_mb{col="size_mb",dbname="DBA",filetype="log",host="127.0.0.1:1433",sql_job="mssql_heavy"} 18.125
sql_mssql_blocked_requests{col="blocked",sql_job="mssql_heavy"} 0
sql_exporter_last_scrape_failed{query="mssql_wait_stats",sql_job="mssql_heavy",...} 0
sql_exporter_query_duration_seconds_count{query="mssql_wait_stats",sql_job="mssql_heavy"} 1
```

它自己的健康 metric 是 `sql_exporter_last_scrape_failed`（每個查詢一個）與 `sql_exporter_query_duration_seconds` histogram。
注意它只有 gauge、沒有逐查詢逾時；`label` 欄位一律要是字串、`values` 欄位請 `CAST(... AS float)`。

## Docker（未在本機實測）

`docker-compose.yml` 會 build 本地 Dockerfile 並拉一個 `mssql/server:2017-latest`，兩邊的密碼
都寫在 yml 裡（`yourStrong(!)Password`）。Dockerfile 用 `PublishSingleFile + self-contained` 放進
`runtime-deps:8.0` 映像；**沒有** `PublishTrimmed`，因為 .NET 7 起預設全量修剪，會把 Newtonsoft 與
Serilog.Settings.Configuration 靠反射載入的型別剪掉。本次只在 Windows 建置與執行，Docker 路徑僅由 CI 的
`docker build` 確認建得起來，沒有實際跑過容器。

## 已知限制

- **整合驗證不能用純 IP 當 Server。** `Microsoft.Data.SqlClient` 對 `Server=tcp:127.0.0.1,1433;Integrated Security=True`
  會用 IP 組 Kerberos SPN 而失敗（`無法產生 SSPI 內容`），舊驅動會退回 NTLM 所以以前能用。實測
  `localhost` 或主機名稱都正常；一定要用 IP 的話加 `Server SPN=MSSQLSvc/<主機名>:1433`。SQL 登入不受影響。
- **`Encrypt` 預設變成 true。** `Microsoft.Data.SqlClient` 4.0 起連線字串沒寫 `Encrypt` 就會要求加密並驗證憑證，
  沒有正式憑證的 SQL Server 會連不上。連線字串請明寫 `Encrypt=False` 或 `TrustServerCertificate=True`。
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
- 沒有任何自動化測試。
