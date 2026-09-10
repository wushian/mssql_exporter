using System;
using System.Linq;
using mssql_exporter.core.config;
using mssql_exporter.core.queries;
using Serilog;

namespace mssql_exporter.core
{
    public static class MetricQueryFactory
    {
        public static IQuery GetSpecificQuery(Prometheus.MetricFactory metricFactory, MetricQuery metricQuery, ILogger logger)
        {
            logger.Information("Creating metric {Name}", metricQuery.Name);
            switch (metricQuery.QueryUsage)
            {
                case QueryUsage.Counter:
                    return new CounterGroupQuery(
                        metricQuery.Name,
                        metricQuery.Description ?? string.Empty,
                        metricQuery.Query,
                        LabelColumns(metricQuery, ColumnUsage.CounterLabel),
                        ValueColumn(metricQuery, ColumnUsage.Counter),
                        metricFactory,
                        metricQuery.MillisecondTimeout);

                case QueryUsage.Gauge:
                    return new GaugeGroupQuery(
                        metricQuery.Name,
                        metricQuery.Description ?? string.Empty,
                        metricQuery.Query,
                        LabelColumns(metricQuery, ColumnUsage.GaugeLabel),
                        ValueColumn(metricQuery, ColumnUsage.Gauge),
                        metricFactory,
                        metricQuery.MillisecondTimeout);

                case QueryUsage.Empty:
                    var gaugeColumns =
                        metricQuery.Columns
                        .Where(x => x.ColumnUsage == ColumnUsage.Gauge)
                        .Select(x => new GenericQuery.GaugeColumn(x.Name, x.Label, x.Description ?? x.Label, metricFactory, x.DefaultValue))
                        .ToArray();

                    var counterColumns =
                        metricQuery.Columns
                        .Where(x => x.ColumnUsage == ColumnUsage.Counter)
                        .Select(x => new GenericQuery.CounterColumn(x.Name, x.Label, x.Description ?? x.Label, metricFactory))
                        .ToArray();

                    return new GenericQuery(metricQuery.Name, metricQuery.Query, gaugeColumns, counterColumns, logger, metricQuery.MillisecondTimeout);

                default:
                    logger.Error("Failed to create query {Name}", metricQuery.Name);
                    break;
            }

            throw new Exception("Undefined QueryUsage.");
        }

        private static LabelledGroupQuery.Column[] LabelColumns(MetricQuery metricQuery, ColumnUsage usage)
        {
            return metricQuery.Columns
                .Where(x => x.ColumnUsage == usage)
                .Select(x => new LabelledGroupQuery.Column(x.Name, x.Order ?? 0, x.Label))
                .ToArray();
        }

        private static LabelledGroupQuery.Column ValueColumn(MetricQuery metricQuery, ColumnUsage usage)
        {
            return metricQuery.Columns
                .Where(x => x.ColumnUsage == usage)
                .Select(x => new LabelledGroupQuery.Column(x.Name, x.Order ?? 0, x.Label))
                .FirstOrDefault();
        }
    }
}
