using System.Collections.Generic;
using Prometheus;

namespace mssql_exporter.core.queries
{
    /// <summary>
    /// "CountersWithLabels": every row becomes one labelled sample of a single counter.
    /// Values only move up (see CounterExtensions.Set); a series is removed on failure.
    /// </summary>
    public class CounterGroupQuery : LabelledGroupQuery
    {
        private readonly Counter _counter;

        public CounterGroupQuery(string name, string description, string query, IEnumerable<Column> labelColumns, Column valueColumn, MetricFactory metricFactory, int? millisecondTimeout)
            : base(name, query, labelColumns, valueColumn, millisecondTimeout)
        {
            _counter = metricFactory.CreateCounter(name, description, new CounterConfiguration
            {
                LabelNames = LabelNames
            });
        }

        protected override void Publish(string[] labels, double value)
        {
            _counter.WithLabels(labels).Set(value);
        }

        protected override void Remove(string[] labels)
        {
            _counter.RemoveLabelled(labels);
        }
    }
}
