using System;
using System.Collections.Generic;

namespace mssql_exporter.core.queries
{
    /// <summary>
    /// Compares Prometheus label value arrays element by element so they can be used as set keys.
    /// </summary>
    public sealed class LabelSetComparer : IEqualityComparer<string[]>
    {
        public static readonly LabelSetComparer Instance = new LabelSetComparer();

        public bool Equals(string[] x, string[] y)
        {
            if (ReferenceEquals(x, y))
            {
                return true;
            }

            if (x is null || y is null || x.Length != y.Length)
            {
                return false;
            }

            for (int i = 0; i < x.Length; i++)
            {
                if (!string.Equals(x[i], y[i], StringComparison.Ordinal))
                {
                    return false;
                }
            }

            return true;
        }

        public int GetHashCode(string[] obj)
        {
            var hash = default(HashCode);
            foreach (var value in obj)
            {
                hash.Add(value, StringComparer.Ordinal);
            }

            return hash.ToHashCode();
        }
    }
}
