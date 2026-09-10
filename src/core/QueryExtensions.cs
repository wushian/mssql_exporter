using System;
using System.Data;
using System.Data.SqlClient;
using System.Threading;
using System.Threading.Tasks;
using mssql_exporter.core.config;
using Serilog;

namespace mssql_exporter.core
{
    public static class QueryExtensions
    {
        /// <summary>
        /// Extra time given to the worker after the timeout fires, so that SqlCommand.Cancel
        /// can reach the server and the worker can report Timeout itself. Only if the worker
        /// is still stuck after this grace period does the caller give up on it.
        /// </summary>
        private const int CancelGraceMilliseconds = 2_000;

        public static async Task<MeasureResult> MeasureWithConnection(this IQuery query, ILogger logger, string sqlConnectionString, int defaultMillisecondTimeout)
        {
            var timeout = Math.Min(defaultMillisecondTimeout, query.MillisecondTimeout ?? 100_000_000);
            var tokenSource = new CancellationTokenSource(timeout);
            var token = tokenSource.Token;

            var measureTask = Task.Run(() =>
            {
                try
                {
                    using (var sqlConnection = new SqlConnection(sqlConnectionString))
                    {
                        sqlConnection.Open();
                        token.ThrowIfCancellationRequested();

                        using (var dataset = new DataSet())
                        using (var command = new SqlCommand(query.Query, sqlConnection))
                        {
                            // CommandTimeout makes SqlClient send an attention packet so the query
                            // is actually stopped on the server instead of running to completion.
                            command.CommandTimeout = Math.Max(1, (int)Math.Ceiling(timeout / 1000.0));

                            using (token.Register(command.Cancel))
                            using (var adapter = new SqlDataAdapter { SelectCommand = command })
                            {
                                adapter.Fill(dataset);
                            }

                            token.ThrowIfCancellationRequested();
                            query.Measure(dataset);
                            return MeasureResult.Success;
                        }
                    }
                }
                catch (OperationCanceledException error)
                {
                    logger.Error(error, "Query {Name} timed out", query.Name);
                    query.Clear();
                    return MeasureResult.Timeout;
                }
                catch (SqlException error) when (error.Number == -2 || token.IsCancellationRequested)
                {
                    // -2 is SqlClient's "Timeout expired"; a cancelled token means our Cancel() fired.
                    logger.Error(error, "Query {Name} timed out", query.Name);
                    query.Clear();
                    return MeasureResult.Timeout;
                }
                catch (Exception error)
                {
                    query.Clear();
                    logger.Error(error, "Query {Name} failed", query.Name);
                    return MeasureResult.Exception;
                }
            });

#pragma warning disable CA2007 // Do not directly await a Task
            var completed = await Task.WhenAny(measureTask, Task.Delay(timeout + CancelGraceMilliseconds));
#pragma warning restore CA2007 // Do not directly await a Task

            if (completed == measureTask)
            {
                tokenSource.Dispose();
#pragma warning disable CA2007 // Do not directly await a Task
                return await measureTask;
#pragma warning restore CA2007 // Do not directly await a Task
            }

            // The worker did not honour cancellation in time; let it dispose the token source when it finishes.
            _ = measureTask.ContinueWith(_ => tokenSource.Dispose(), TaskScheduler.Default);
            logger.Error("Query {Name} did not stop within {Milliseconds} ms of its timeout", query.Name, CancelGraceMilliseconds);
            query.Clear();
            return MeasureResult.Timeout;
        }

        public static int GetColumnIndex(DataTable dataTable, string columnName)
        {
            for (int i = 0; i < dataTable.Columns.Count; i++)
            {
                if (dataTable.Columns[i].ColumnName.Equals(columnName, StringComparison.CurrentCulture))
                {
                    return i;
                }
            }

            throw new ArgumentOutOfRangeException(nameof(columnName), $"Expected to find column {columnName}");
        }
    }
}
