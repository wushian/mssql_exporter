# Grafana dashboard

`mssql_exporter.json` 是一份可直接匯入 Grafana 10 以上的 dashboard，涵蓋兩個 exporter：

| Row | 資料來源 | 面板 |
|---|---|---|
| mssql_exporter | 每次 scrape 即時查的 `mssql_*` | SQL Server 可達、例外／逾時查詢數、總連線數、範圍內 deadlock 數、Prometheus scrape 狀態；process 狀態、各庫連線、deadlock 速率、exporter 失敗趨勢 |
| sql_exporter | `deploy/sql_exporter/config.yml` 的四個背景查詢 `sql_mssql_*` | 封鎖請求數、失敗查詢數、Page life expectancy、User Connections、Batch Requests/s、總配置大小；吞吐計數器速率、PLE 趨勢、前 10 名 wait 類型、封鎖趨勢；各庫 data/log 大小表、查詢健康表 |

## 匯入

Grafana → Dashboards → New → Import → 上傳 `mssql_exporter.json` → 選 Prometheus data source → Import。

`uid` 固定為 `mssql-exporter-overview`，重新匯入新版會**更新同一份** dashboard（星號、權限、alert 引用都保留），
不會疊出第二份。

## 模板變數

| 變數 | 來源 | 過濾哪些面板 |
|---|---|---|
| `DS_PROMETHEUS` | 匯入時選的 data source | 全部 |
| `instance` | `label_values(mssql_up, instance)`，即 Prometheus 上 mssql_exporter 的 scrape target | 第一個 row |
| `host` | `label_values(sql_exporter_last_scrape_failed, host)`，即 sql_exporter 設定裡的 SQL Server 位址 | 第二個 row |

只部署 mssql_exporter 的話，第二個 row 全部 No data 是正常的；`host` 變數會是空的。

## 幾個查詢上的判斷

- `mssql_deadlocks` 與 `sql_mssql_perf_counter` 裡的 `Batch Requests/sec`、`Transactions/sec`、`Lock Waits/sec`
  雖然是 gauge 型別、名字帶 `/sec`，但 SQL Server 給的是**自重啟以來的累計值**，所以一律經 `rate()` 或 `increase()`。
- `Page life expectancy`、`User Connections` 是真正的即時值，直畫。
- wait stats 用 `rate(wait_time_ms)`，單位是「每秒累積幾毫秒的等待」，1000 代表隨時有一個工作在等這種類型。
- sql_exporter 的 perf counter 查詢有個叫 `instance` 的欄位，Prometheus 抓取時會和 target 的 `instance` 衝突而改名為
  `exported_instance`。dashboard 不靠這個 label，只靠 `counter`。
- `sql_exporter_query_duration_seconds` 沒有 `host` label，查詢健康表的 p95 欄不受 `host` 變數過濾。

## 驗證狀態

- **已驗證**：JSON 可解析、panel id 唯一、多 target 面板的 refId 唯一、所有引用的 metric 都存在於程式碼或 `config.yml`、
  每條查詢都掛了對應的模板變數。
- **未驗證**：實際匯入 Grafana 的渲染結果（transformation 欄名、單位字串）。面板結構沿用已在真實 Grafana 匯入過的骨架。
