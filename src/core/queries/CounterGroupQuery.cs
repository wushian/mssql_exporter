using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;
using Prometheus;
using Serilog;

namespace mssql_exporter.core.queries
{
#pragma warning disable CA1034 // Nested types should not be visible
    public class CounterGroupQuery : IQuery
    {
        private readonly IEnumerable<Column> _labelColumns;
        private readonly Counter _counter;
        private readonly Column _valueColumn;
        private readonly ILogger _logger;
        private readonly object _publishedLock = new object();
        private HashSet<string[]> _published = new HashSet<string[]>(LabelSetComparer.Instance);

        public CounterGroupQuery(string name, string description, string query, IEnumerable<Column> labelColumns, Column valueColumn, MetricFactory metricFactory, ILogger logger, int? millisecondTimeout)
        {
            Name = name;
            Query = query;
            this._valueColumn = valueColumn;
            _logger = logger;
            MillisecondTimeout = millisecondTimeout;
            this._labelColumns = labelColumns.OrderBy(x => x.Order).ToArray();

            var counterConfiguration = new Prometheus.CounterConfiguration
            {
                LabelNames = this._labelColumns.Select(x => x.Label).ToArray()
            };

            _counter = metricFactory.CreateCounter(name, description, counterConfiguration);
        }

        public string Name { get; }

        public string Query { get; }

        public int? MillisecondTimeout { get; }

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
                    _counter.RemoveLabelled(labels);
                }

                _published = new HashSet<string[]>(LabelSetComparer.Instance);
            }
        }

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
                    _counter.WithLabels(labels).Set(result);
                    seen.Add(labels);
                }
            }

            lock (_publishedLock)
            {
                foreach (var stale in _published.Where(x => !seen.Contains(x)))
                {
                    _counter.RemoveLabelled(stale);
                }

                _published = seen;
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
