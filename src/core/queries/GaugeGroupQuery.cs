using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using Prometheus;
using Serilog;

namespace mssql_exporter.core.queries
{
#pragma warning disable CA1034 // Nested types should not be visible
    public class GaugeGroupQuery : IQuery
    {
        private readonly IEnumerable<Column> _labelColumns;
        private readonly Prometheus.Gauge _gauge;
        private readonly Column _valueColumn;
        private readonly ILogger _logger;
        private readonly object _publishedLock = new object();
        private HashSet<string[]> _published = new HashSet<string[]>(LabelSetComparer.Instance);

        public GaugeGroupQuery(string name, string description, string query, IEnumerable<Column> labelColumns, Column valueColumn, MetricFactory metricFactory, ILogger logger, int? millisecondTimeout)
        {
            Name = name;
            Query = query;
            MillisecondTimeout = millisecondTimeout;
            this._valueColumn = valueColumn;
            _logger = logger;
            this._labelColumns = labelColumns.OrderBy(x => x.Order).ToArray();

            var gaugeConfiguration = new Prometheus.GaugeConfiguration
            {
                LabelNames = this._labelColumns.Select(x => x.Label).ToArray(),
                SuppressInitialValue = true
            };

            _gauge = metricFactory.CreateGauge(name, description, gaugeConfiguration);
        }

        public string Name { get; }

        public string Query { get; }

        public int? MillisecondTimeout { get; }

        public void Measure(DataSet dataSet)
        {
            var table = dataSet.Tables[0];

            var columnIndices = _labelColumns.Select(x => QueryExtensions.GetColumnIndex(table, x.Name)).ToArray();
            var valueIndex = QueryExtensions.GetColumnIndex(table, _valueColumn.Name);

            var seen = new HashSet<string[]>(LabelSetComparer.Instance);
            foreach (var row in table.Rows.Cast<DataRow>())
            {
                var labels = columnIndices.Select(x => row.ItemArray[x].ToString().Trim()).ToArray();
                if (double.TryParse(row.ItemArray[valueIndex].ToString(), out double result))
                {
                    _gauge.WithLabels(labels).Set(result);
                    seen.Add(labels);
                }
            }

            // Label sets present in the previous result but absent from this one would otherwise
            // keep reporting their last value forever.
            lock (_publishedLock)
            {
                foreach (var stale in _published.Where(x => !seen.Contains(x)))
                {
                    _gauge.RemoveLabelled(stale);
                }

                _published = seen;
            }
        }

        /// <summary>
        /// Called on timeout or exception: drop every label set from the last successful
        /// measurement so stale values are not served while the database is unreachable.
        /// </summary>
        public void Clear()
        {
            lock (_publishedLock)
            {
                foreach (var labels in _published)
                {
                    _gauge.RemoveLabelled(labels);
                }

                _published = new HashSet<string[]>(LabelSetComparer.Instance);
            }
        }

        public class Column
        {
            public Column(string name, int order, string label)
            {
                if (string.IsNullOrWhiteSpace(name))
                {
                    throw new ArgumentException("Expected name argument", nameof(name));
                }

                if (string.IsNullOrWhiteSpace(label))
                {
                    throw new ArgumentException("expected label argument", nameof(label));
                }

                Name = name;
                Order = order;
                Label = label;
            }

            public string Name { get; }

            public int Order { get; }

            public string Label { get; }
        }
    }
#pragma warning restore CA1034
}
