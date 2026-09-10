using System.Collections.Generic;
using Prometheus;

namespace mssql_exporter.core.queries
{
    /// <summary>
    /// "GaugesWithLabels": every row becomes one labelled sample of a single gauge.
    /// </summary>
    public class GaugeGroupQuery : LabelledGroupQuery
    {
        private readonly Gauge _gauge;

        public GaugeGroupQuery(string name, string description, string query, IEnumerable<Column> labelColumns, Column valueColumn, MetricFactory metricFactory, int? millisecondTimeout)
            : base(name, query, labelColumns, valueColumn, millisecondTimeout)
        {
            _gauge = metricFactory.CreateGauge(name, description, new GaugeConfiguration
            {
                LabelNames = LabelNames,
                SuppressInitialValue = true
            });
        }

        protected override void Publish(string[] labels, double value)
        {
            _gauge.WithLabels(labels).Set(value);
        }

        protected override void Remove(string[] labels)
        {
            _gauge.RemoveLabelled(labels);
        }
    }
}
