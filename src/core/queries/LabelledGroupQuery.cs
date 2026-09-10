using System;
using System.Collections.Generic;
using System.Data;
using System.Linq;

namespace mssql_exporter.core.queries
{
#pragma warning disable CA1034 // Nested types should not be visible
    /// <summary>
    /// Shared implementation for "one query, one labelled metric, one row per label set".
    /// Derived classes only decide which Prometheus collector receives the values.
    /// </summary>
    public abstract class LabelledGroupQuery : IQuery
    {
        private readonly Column[] _labelColumns;
        private readonly Column _valueColumn;
        private readonly object _publishedLock = new object();
        private HashSet<string[]> _published = new HashSet<string[]>(LabelSetComparer.Instance);

        protected LabelledGroupQuery(string name, string query, IEnumerable<Column> labelColumns, Column valueColumn, int? millisecondTimeout)
        {
            if (string.IsNullOrWhiteSpace(name))
            {
                throw new ArgumentException("Expected name argument", nameof(name));
            }

            Name = name;
            Query = query;
            MillisecondTimeout = millisecondTimeout;
            _labelColumns = (labelColumns ?? Enumerable.Empty<Column>()).OrderBy(x => x.Order).ToArray();
            _valueColumn = valueColumn ?? throw new ArgumentException($"Query {name} needs exactly one column whose Usage is the value column (Gauge or Counter)", nameof(valueColumn));
        }

        public string Name { get; }

        public string Query { get; }

        public int? MillisecondTimeout { get; }

        /// <summary>
        /// Prometheus label names in column order; available to derived constructors.
        /// </summary>
        protected string[] LabelNames => _labelColumns.Select(x => x.Label).ToArray();

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
                    Publish(labels, result);
                    seen.Add(labels);
                }
            }

            // Label sets present in the previous result but absent from this one would otherwise
            // keep reporting their last value forever.
            lock (_publishedLock)
            {
                foreach (var stale in _published.Where(x => !seen.Contains(x)))
                {
                    Remove(stale);
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
                    Remove(labels);
                }

                _published = new HashSet<string[]>(LabelSetComparer.Instance);
            }
        }

        protected abstract void Publish(string[] labels, double value);

        protected abstract void Remove(string[] labels);

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
