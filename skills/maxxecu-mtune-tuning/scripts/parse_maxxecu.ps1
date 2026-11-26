param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [string]$TunePath = "",
    [double]$MinClt = 70.0,
    [double]$MaxDTps = 3.0,
    [double]$MaxDMap = 8.0,
    [int]$MinHits = 5,
    [double]$ApplyFactor = 0.65,
    [int]$LambdaOffsetMs = 0,
    [switch]$DumpTables,
    [string]$ExportVeTable = "",
    [string]$ExportCsv = ""
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
}
if ($TunePath -ne "" -and -not (Test-Path -LiteralPath $TunePath)) {
    throw "Tune file not found: $TunePath"
}

$csCode = @'
using System;
using System.IO;
using System.IO.Compression;
using System.Xml;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Linq;
using System.Globalization;

public class MaxxEcuAnalyzerV2 {
    public class DynamicTableModel {
        public string Name;
        public int XSrc;
        public int YSrc;
        public int ZSrc;
        public double[] XAxis;
        public double[] YAxis;
        public double[] ZAxis;
        public double[,] Values; // [y, x]
    }

    public class TuneModel {
        public string SourceName;
        public Dictionary<string, string> FileInfo = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, string> Settings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, DynamicTableModel> Tables = new Dictionary<string, DynamicTableModel>(StringComparer.OrdinalIgnoreCase);

        public string GetSetting(string key, string defVal) {
            string v;
            return Settings.TryGetValue(key, out v) ? v : defVal;
        }
        public double GetSettingDouble(string key, double defVal) {
            string v;
            double d;
            if (Settings.TryGetValue(key, out v) && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d)) {
                return d;
            }
            return defVal;
        }
    }

    public class ColumnMeta {
        public int RawIndex;
        public string RawHeader;
        public string CleanName;
        public string Unit;
        public int ChannelId; // -1 if none
        public string Role;
    }

    public class LogModel {
        public string SourceName;
        public char Delimiter;
        public int TotalRawColumns;
        public double MetaLogRate; // seconds per sample from .LogMetaData if present
        public List<ColumnMeta> KeptCols = new List<ColumnMeta>();
        public Dictionary<string, int> RoleToKeptIdx = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public List<double[]> Columns = new List<double[]>(); // [keptIdx][row]
        public int RowCount;

        public int GetKept(string role) {
            int idx;
            return RoleToKeptIdx.TryGetValue(role, out idx) ? idx : -1;
        }
    }

    static double ParseInv(string s) {
        if (string.IsNullOrWhiteSpace(s)) return double.NaN;
        string t = s.Trim();
        double v;
        if (double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
        if (t.IndexOf(',') >= 0 && t.IndexOf('.') < 0) {
            if (double.TryParse(t.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
        }
        return double.NaN;
    }

    static double[] ParseDoubleList(string csv) {
        if (string.IsNullOrWhiteSpace(csv)) return new double[0];
        var parts = csv.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        var res = new double[parts.Length];
        for (int i = 0; i < parts.Length; i++) res[i] = ParseInv(parts[i]);
        return res;
    }

    static string AxisSourceName(int id) {
        switch (id) {
            case 5: return "Lambda";
            case 17: return "IAT (C)";
            case 18: return "CLT (C)";
            case 19: return "TPS (%)";
            case 20: return "MAP (kPa)";
            case 61: return "RPM";
            case 69: return "Runtime (s)";
            case 89: return "VSS Speed";
            case 90: return "Gear";
            case 95: return "Baro (kPa)";
            case 103: return "TPS Rate (%/s)";
            case 136: return "EGT Highest (C)";
            case 204: return "Main Throttle (%)";
            case 246: return "Ethanol (%)";
            case 247: return "Fuel Temp (C)";
            case 254: return "Undriven Speed";
            case 273: return "Fuel Load (%)";
            case 280: return "Boost Target MAP (kPa)";
            case 311: return "MAP / Load (kPa)";
            case 499: return "Primary Fuel Press (kPa)";
            case 562: return "Idle RPM Error";
            default: return "Src#" + id;
        }
    }

    static string ReadTextSmart(byte[] bytes) {
        if (bytes.Length >= 2) {
            if (bytes[0] == 0xFF && bytes[1] == 0xFE) return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
            if (bytes[0] == 0xFE && bytes[1] == 0xFF) return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);
            if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) return Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
        }
        int zeroOdd = 0;
        int sampleLen = Math.Min(bytes.Length, 200);
        for (int i = 1; i < sampleLen; i += 2) if (bytes[i] == 0) zeroOdd++;
        if (sampleLen > 20 && zeroOdd > sampleLen / 3) return Encoding.Unicode.GetString(bytes);
        return Encoding.UTF8.GetString(bytes);
    }

    static bool LooksBinaryStream(Stream s) {
        byte[] buf = new byte[2048];
        int n = s.Read(buf, 0, buf.Length);
        if (n == 0) return false;
        if (n >= 2 && ((buf[0] == 0xFF && buf[1] == 0xFE) || (buf[0] == 0xFE && buf[1] == 0xFF))) return false;
        int bad = 0;
        for (int i = 0; i < n; i++) {
            byte b = buf[i];
            if (b == 0 || (b < 32 && b != 9 && b != 10 && b != 13)) bad++;
        }
        return (double)bad / n > 0.08;
    }

    static TuneModel ParseTuneXml(string xmlText, string sourceName) {
        var model = new TuneModel();
        model.SourceName = sourceName;
        string clean = Regex.Replace(xmlText, @"encoding\s*=\s*[""']utf-16[""']", @"encoding=""utf-8""", RegexOptions.IgnoreCase);
        var doc = new XmlDocument();
        doc.LoadXml(clean);
        var root = doc.DocumentElement;
        if (root == null) throw new Exception("Invalid MaxxECU XML root.");

        var fi = root.SelectSingleNode("Fileinfo");
        if (fi != null) {
            foreach (XmlNode n in fi.ChildNodes) {
                if (n.NodeType == XmlNodeType.Element) model.FileInfo[n.LocalName] = n.InnerText.Trim();
            }
        }

        foreach (XmlNode n in root.SelectNodes("ECUSettingsItem")) {
            var el = n as XmlElement;
            if (el == null) continue;
            string name = el.GetAttribute("name");
            if (!string.IsNullOrEmpty(name)) model.Settings[name] = el.InnerText.Trim();
        }

        foreach (XmlNode n in root.SelectNodes("DynamicTable")) {
            var el = n as XmlElement;
            if (el == null) continue;
            string tname = el.GetAttribute("name");
            if (string.IsNullOrEmpty(tname)) continue;

            var tbl = new DynamicTableModel();
            tbl.Name = tname;
            var xNode = el.SelectSingleNode("DynamicTableAxis[@name='X']") as XmlElement;
            var yNode = el.SelectSingleNode("DynamicTableAxis[@name='Y']") as XmlElement;
            var zNode = el.SelectSingleNode("DynamicTableAxis[@name='Z']") as XmlElement;
            if (xNode != null) {
                int s; if (int.TryParse(xNode.GetAttribute("AxisDataSource"), out s)) tbl.XSrc = s;
                tbl.XAxis = ParseDoubleList(xNode.InnerText);
            } else tbl.XAxis = new double[0];
            if (yNode != null) {
                int s; if (int.TryParse(yNode.GetAttribute("AxisDataSource"), out s)) tbl.YSrc = s;
                tbl.YAxis = ParseDoubleList(yNode.InnerText);
            } else tbl.YAxis = new double[0];
            if (zNode != null) {
                int s; if (int.TryParse(zNode.GetAttribute("AxisDataSource"), out s)) tbl.ZSrc = s;
                tbl.ZAxis = ParseDoubleList(zNode.InnerText);
            } else tbl.ZAxis = new double[0];

            var dataNode = el.SelectSingleNode("DynamicTableData") as XmlElement;
            if (dataNode != null) {
                int xs = 0, ys = 0;
                int.TryParse(dataNode.GetAttribute("XSize"), out xs);
                int.TryParse(dataNode.GetAttribute("YSize"), out ys);
                if (xs > 0 && ys > 0) {
                    var rows = dataNode.InnerText.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                    tbl.Values = new double[ys, xs];
                    for (int r = 0; r < Math.Min(ys, rows.Length); r++) {
                        var cols = rows[r].Split(',');
                        for (int c = 0; c < Math.Min(xs, cols.Length); c++) {
                            tbl.Values[r, c] = ParseInv(cols[c]);
                        }
                    }
                }
            }
            model.Tables[tname] = tbl;
        }
        return model;
    }

    static double BilinearLookup(DynamicTableModel tbl, double xVal, double yVal) {
        if (tbl == null || tbl.Values == null || tbl.XAxis.Length == 0 || tbl.YAxis.Length == 0) return double.NaN;
        int nx = tbl.XAxis.Length, ny = tbl.YAxis.Length;
        int ix0 = 0, ix1 = 0; double fx = 0;
        if (xVal <= tbl.XAxis[0]) { ix0 = ix1 = 0; }
        else if (xVal >= tbl.XAxis[nx - 1]) { ix0 = ix1 = nx - 1; }
        else {
            for (int i = 0; i < nx - 1; i++) {
                if (xVal >= tbl.XAxis[i] && xVal <= tbl.XAxis[i + 1]) {
                    ix0 = i; ix1 = i + 1;
                    double d = tbl.XAxis[i + 1] - tbl.XAxis[i];
                    fx = d > 0 ? (xVal - tbl.XAxis[i]) / d : 0;
                    break;
                }
            }
        }
        int iy0 = 0, iy1 = 0; double fy = 0;
        if (yVal <= tbl.YAxis[0]) { iy0 = iy1 = 0; }
        else if (yVal >= tbl.YAxis[ny - 1]) { iy0 = iy1 = ny - 1; }
        else {
            for (int i = 0; i < ny - 1; i++) {
                if (yVal >= tbl.YAxis[i] && yVal <= tbl.YAxis[i + 1]) {
                    iy0 = i; iy1 = i + 1;
                    double d = tbl.YAxis[i + 1] - tbl.YAxis[i];
                    fy = d > 0 ? (yVal - tbl.YAxis[i]) / d : 0;
                    break;
                }
            }
        }
        double v0 = tbl.Values[iy0, ix0] + (tbl.Values[iy0, ix1] - tbl.Values[iy0, ix0]) * fx;
        double v1 = tbl.Values[iy1, ix0] + (tbl.Values[iy1, ix1] - tbl.Values[iy1, ix0]) * fx;
        return v0 + (v1 - v0) * fy;
    }

    static string[] SplitLineFast(string line, char delim) {
        if (line.IndexOf('"') < 0) return line.Split(delim);
        var result = new List<string>();
        var sb = new StringBuilder();
        bool inQuotes = false;
        for (int i = 0; i < line.Length; i++) {
            char ch = line[i];
            if (ch == '"') {
                if (inQuotes && i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; }
                else inQuotes = !inQuotes;
            } else if (ch == delim && !inQuotes) {
                result.Add(sb.ToString());
                sb.Clear();
            } else sb.Append(ch);
        }
        result.Add(sb.ToString());
        return result.ToArray();
    }

    static bool IsNumericArray(string[] fields) {
        int numeric = 0, nonEmpty = 0;
        int lim = Math.Min(fields.Length, 40);
        for (int i = 0; i < lim; i++) {
            if (string.IsNullOrWhiteSpace(fields[i])) continue;
            nonEmpty++;
            if (!double.IsNaN(ParseInv(fields[i]))) numeric++;
        }
        return nonEmpty >= 3 && (double)numeric / nonEmpty >= 0.7;
    }

    static ColumnMeta ParseHeaderMeta(int idx, string raw) {
        var cm = new ColumnMeta();
        cm.RawIndex = idx;
        cm.RawHeader = raw.Trim();
        cm.ChannelId = -1;
        cm.Unit = "";
        string h = cm.RawHeader;

        // Check MaxxECU native [ChannelID] suffix e.g. "RPM [61]"
        var mId = Regex.Match(h, @"^(.*?)\s*\[(\d+)\]\s*$");
        if (mId.Success) {
            h = mId.Groups[1].Value.Trim();
            int cid;
            if (int.TryParse(mId.Groups[2].Value, out cid)) cm.ChannelId = cid;
        }
        // Check unit suffix in parentheses e.g. "MAP (kPa)"
        var mUnit = Regex.Match(h, @"^(.*?)\s*\(([^\)]+)\)\s*$");
        if (mUnit.Success) {
            h = mUnit.Groups[1].Value.Trim();
            cm.Unit = mUnit.Groups[2].Value.Trim();
        }
        cm.CleanName = h;
        return cm;
    }

    static int FindMetaByIdOrName(List<ColumnMeta> metas, int[] ids, string[] exactNames, string[] regexNames, HashSet<int> used) {
        if (ids != null) {
            foreach (int id in ids) {
                for (int i = 0; i < metas.Count; i++) {
                    if (used.Contains(i)) continue;
                    if (metas[i].ChannelId == id) return i;
                }
            }
        }
        if (exactNames != null) {
            foreach (var n in exactNames) {
                for (int i = 0; i < metas.Count; i++) {
                    if (used.Contains(i)) continue;
                    if (string.Equals(metas[i].CleanName, n, StringComparison.OrdinalIgnoreCase)) return i;
                }
            }
        }
        if (regexNames != null) {
            foreach (var p in regexNames) {
                var rx = new Regex(p, RegexOptions.IgnoreCase);
                for (int i = 0; i < metas.Count; i++) {
                    if (used.Contains(i)) continue;
                    if (rx.IsMatch(metas[i].CleanName)) return i;
                }
            }
        }
        return -1;
    }

    static LogModel ParseLogStream(Stream stream, string sourceName, double metaLogRate, int veYSrcId) {
        var log = new LogModel();
        log.SourceName = sourceName;
        log.MetaLogRate = metaLogRate;

        using (var sr = new StreamReader(stream, Encoding.UTF8, true, 65536)) {
            var preamble = new List<string>();
            string line;
            while (preamble.Count < 25 && (line = sr.ReadLine()) != null) {
                if (!string.IsNullOrWhiteSpace(line)) preamble.Add(line);
            }
            if (preamble.Count < 2) throw new Exception("Log file has too few lines.");

            int headerIdx = -1;
            char bestDelim = '\t';
            for (int i = 0; i < preamble.Count - 1; i++) {
                string ln = preamble[i].Trim();
                if (ln.StartsWith("#") || ln.StartsWith("//")) continue;
                int tabs = ln.Count(c => c == '\t');
                int commas = ln.Count(c => c == ',');
                int semis = ln.Count(c => c == ';');
                char d = '\t'; int cnt = tabs;
                if (commas > cnt) { d = ','; cnt = commas; }
                if (semis > cnt) { d = ';'; cnt = semis; }
                if (cnt >= 3) {
                    var fields = SplitLineFast(ln, d);
                    if (!IsNumericArray(fields)) {
                        bool hasData = false;
                        for (int k = i + 1; k < Math.Min(preamble.Count, i + 4); k++) {
                            if (IsNumericArray(SplitLineFast(preamble[k], d))) { hasData = true; break; }
                        }
                        if (hasData) { headerIdx = i; bestDelim = d; break; }
                    }
                }
            }
            if (headerIdx < 0) throw new Exception("Could not locate tabular column headers in log file.");

            log.Delimiter = bestDelim;
            var rawHeaders = SplitLineFast(preamble[headerIdx], bestDelim);
            log.TotalRawColumns = rawHeaders.Length;

            var allMetas = new List<ColumnMeta>(rawHeaders.Length);
            for (int c = 0; c < rawHeaders.Length; c++) allMetas.Add(ParseHeaderMeta(c, rawHeaders[c]));

            int dataStartInPreamble = headerIdx + 1;
            if (dataStartInPreamble < preamble.Count) {
                var nextFields = SplitLineFast(preamble[dataStartInPreamble], bestDelim);
                if (!IsNumericArray(nextFields) && nextFields.Length >= Math.Min(10, rawHeaders.Length / 2)) {
                    for (int c = 0; c < Math.Min(allMetas.Count, nextFields.Length); c++) {
                        if (string.IsNullOrEmpty(allMetas[c].Unit) && !string.IsNullOrEmpty(nextFields[c])) {
                            allMetas[c].Unit = nextFields[c].Trim('[', ']', '(', ')');
                        }
                    }
                    dataStartInPreamble++;
                }
            }

            // Select semantic columns (by exact MaxxECU RT-Data Channel ID first, then name fallback)
            var used = new HashSet<int>();
            Action<string, int[], string[], string[]> mapRole = (role, ids, exacts, regexes) => {
                int idx = FindMetaByIdOrName(allMetas, ids, exacts, regexes, used);
                if (idx >= 0) {
                    used.Add(idx);
                    allMetas[idx].Role = role;
                    log.RoleToKeptIdx[role] = log.KeptCols.Count;
                    log.KeptCols.Add(allMetas[idx]);
                }
            };

            mapRole("TIME", null, new[] { "Time", "TimeStamp", "Log time" }, new[] { @"^time$", @"^timestamp$", @"^log\s*time$" });
            mapRole("RUNTIME", new[] { 69 }, new[] { "Engine runtime" }, null);
            mapRole("RPM", new[] { 61 }, new[] { "RPM", "Engine speed" }, new[] { @"\brpm\b", @"^engine\s*speed$" });
            mapRole("MAP", new[] { 20 }, new[] { "MAP", "Manifold absolute pressure" }, new[] { @"^map$", @"manifold.*press" });
            if (veYSrcId > 0 && veYSrcId != 20 && veYSrcId != 19) {
                mapRole("VE_LOAD", new[] { veYSrcId }, null, null);
            }
            mapRole("BARO", new[] { 95 }, new[] { "Baro pressure" }, new[] { @"^baro" });
            mapRole("TPS", new[] { 19 }, new[] { "TPS", "Throttle position" }, new[] { @"^tps$", @"^throttle\s*position$" });
            mapRole("LAMBDA", new[] { 5 }, new[] { "Lambda", "Lambda avg", "AFR" }, new[] { @"^lambda$", @"lambda\s*avg", @"^afr$" });
            mapRole("LAMBDA_A", new[] { 110 }, new[] { "Lambda A", "Lambda 1", "WBO A", "AFR A" }, new[] { @"^(lambda|wbo|afr)\s*(a|1)$" });
            mapRole("LAMBDA_B", new[] { 111 }, new[] { "Lambda B", "Lambda 2", "WBO B", "AFR B" }, new[] { @"^(lambda|wbo|afr)\s*(b|2)$" });
            mapRole("LAMBDA_TGT", new[] { 81 }, new[] { "Lambda target", "Target lambda", "AFR target" }, new[] { @"^lambda\s*target$", @"target.*lambda", @"afr.*target" });
            mapRole("LAMBDA_CORR_A", new[] { 102 }, new[] { "Lambda corr A", "Lambda correction A" }, new[] { @"lambda.*corr.*\b(a|1)\b" });
            mapRole("LAMBDA_CORR_B", new[] { 112 }, new[] { "Lambda corr B", "Lambda correction B" }, new[] { @"lambda.*corr.*\b(b|2)\b" });
            mapRole("LAMBDA_CORR", null, new[] { "Lambda corr", "Lambda correction", "Closed loop lambda" }, new[] { @"^lambda\s*corr$", @"closed.*loop.*lam" });
            mapRole("LAMBDA_STATE", new[] { 670 }, new[] { "Lambda corr state" }, null);
            mapRole("LTFT", new[] { 123 }, new[] { "Long term trim 1", "Long term trim", "Fuel adaptation", "LTFT" }, new[] { @"long\s*term.*trim", @"fuel\s*adapt", @"\bltft\b" });
            mapRole("TOT_FUEL_ERR", new[] { 806 }, new[] { "Total Fueling Target Error" }, new[] { @"total.*fuel.*target.*error" });
            mapRole("FUEL_ERR_A", new[] { 664 }, new[] { "Fueling Target Error Bank A" }, null);
            mapRole("FUEL_ERR_B", new[] { 665 }, new[] { "Fueling Target Error Bank B" }, null);
            mapRole("VE_ACTIVE", new[] { 70 }, new[] { "VE table 1", "Fuel VE" }, null);
            mapRole("INJ_PW", new[] { 63 }, new[] { "Fuel pulse primary", "Injection time", "Injector pulse width", "Inj PW" }, new[] { @"inj.*(time|pw|pulse)", @"fuel\s*pulse\s*primary" });
            mapRole("IDC", new[] { 64 }, new[] { "Fuel duty primary", "Injector duty", "Fuel duty" }, new[] { @"(inj|fuel).*duty" });
            mapRole("ACCEL_ENRICH", new[] { 106 }, new[] { "Acc enrichment", "Accel enrich" }, new[] { @"acc.*enrich" });
            mapRole("FUEL_CUT", new[] { 100 }, new[] { "Fuel cut", "Overrun fuel cut" }, new[] { @"^fuel\s*cut$" });
            mapRole("FUEL_CUT_REASON", new[] { 584 }, new[] { "Fuel cut reason" }, null);
            mapRole("IGN_ANGLE", new[] { 60 }, new[] { "Ignition angle", "Ign angle", "Spark advance" }, new[] { @"^ign.*(angle|tim)", @"spark.*adv" });
            mapRole("IGN_CUT", new[] { 101 }, new[] { "Ignition cut", "Ign cut" }, new[] { @"^ign.*cut$" });
            mapRole("IGN_CUT_REASON", new[] { 585 }, new[] { "Ignition cut reason" }, null);
            mapRole("KNOCK_RETARD", new[] { 479 }, new[] { "Knock correction", "Knock retard", "Knock ign retard" }, new[] { @"knock.*(ret|corr)$" });
            mapRole("KNOCK_COUNT", new[] { 488 }, new[] { "Knock Count" }, new[] { @"knock\s*count" });
            mapRole("KNOCK_PEAK", new[] { 656 }, new[] { "Knocklevel All Peak" }, null);
            mapRole("CLT", new[] { 18 }, new[] { "Coolant temp", "CLT", "ECT" }, new[] { @"^clt$", @"coolant\s*temp", @"^ect$" });
            mapRole("IAT", new[] { 17 }, new[] { "Intake air temp", "IAT" }, new[] { @"^iat$", @"intake\s*air\s*temp" });
            mapRole("BATT_V", new[] { 21 }, new[] { "Battery voltage", "Batt V", "VBatt" }, new[] { @"batt.*v", @"^vbatt$" });
            mapRole("ETHANOL", new[] { 813, 246 }, new[] { "Ethanol concentration used", "Ethanol concentration", "Ethanol", "Flex fuel" }, new[] { @"ethanol", @"flex.*fuel" });
            mapRole("FUEL_PRESS", new[] { 499 }, new[] { "Primary fuel pressure", "Fuel pressure", "Fuel press" }, new[] { @"fuel\s*press" });
            mapRole("OIL_PRESS", new[] { 804 }, new[] { "Engine Oil Pressure", "Oil pressure", "Oil press" }, new[] { @"oil\s*press" });
            mapRole("BOOST_TGT", new[] { 280 }, new[] { "Boost Target MAP", "Boost target" }, new[] { @"boost.*target" });
            mapRole("BOOST_DUTY", new[] { 119 }, new[] { "Boost solenoid duty", "Boost duty" }, new[] { @"boost.*(duty|sol)" });
            mapRole("IDLE_AIR", new[] { 563, 77 }, new[] { "Idle ctrl duty Air", "Idle step position", "Idle duty", "IAC" }, new[] { @"idle.*(duty|step|valve)", @"^iac$" });
            mapRole("IDLE_TGT_RPM", new[] { 818 }, new[] { "Idle Target RPM" }, null);
            mapRole("VSS", new[] { 89 }, new[] { "VSS Speed", "Vehicle speed", "VSS" }, new[] { @"^vss\b", @"vehicle\s*speed" });
            mapRole("GEAR", new[] { 90 }, new[] { "VSS Gear", "Gear" }, new[] { @"^gear$" });
            mapRole("TCC_STATUS", new[] { 272 }, new[] { "TCC Status" }, null);
            mapRole("TRANS_SLIP", new[] { 379 }, new[] { "Transmission slip" }, null);
            mapRole("ERR_COUNT", new[] { 108 }, new[] { "Error code count" }, null);
            mapRole("LAST_ERR", new[] { 71 }, new[] { "Last error code" }, null);
            mapRole("IN_SYNC", new[] { 38 }, new[] { "In Sync" }, null);
            mapRole("EGT", new[] { 136 }, new[] { "EGT Highest", "EGT" }, new[] { @"^egt\b" });

            // If small log (<= 30 columns), keep all remaining unmapped columns too for complete inventory
            if (allMetas.Count <= 30) {
                for (int c = 0; c < allMetas.Count; c++) {
                    if (!used.Contains(c) && !string.IsNullOrWhiteSpace(allMetas[c].CleanName)) {
                        used.Add(c);
                        allMetas[c].Role = "";
                        log.KeptCols.Add(allMetas[c]);
                    }
                }
            }

            int nKept = log.KeptCols.Count;
            int[] rawIdxMap = new int[nKept];
            var colLists = new List<double>[nKept];
            for (int k = 0; k < nKept; k++) {
                rawIdxMap[k] = log.KeptCols[k].RawIndex;
                colLists[k] = new List<double>(4096);
            }

            Action<string> processRow = ln => {
                if (string.IsNullOrWhiteSpace(ln) || ln.StartsWith("#")) return;
                var fields = SplitLineFast(ln, bestDelim);
                if (fields.Length < 3) return;
                // Quick sanity check on first kept col
                for (int k = 0; k < nKept; k++) {
                    int ri = rawIdxMap[k];
                    double v = (ri < fields.Length) ? ParseInv(fields[ri]) : double.NaN;
                    colLists[k].Add(v);
                }
            };

            for (int r = dataStartInPreamble; r < preamble.Count; r++) processRow(preamble[r]);
            while ((line = sr.ReadLine()) != null) processRow(line);

            log.RowCount = nKept > 0 ? colLists[0].Count : 0;
            for (int k = 0; k < nKept; k++) log.Columns.Add(colLists[k].ToArray());
        }
        return log;
    }

    static double Median(List<double> vals) {
        if (vals.Count == 0) return double.NaN;
        var arr = vals.ToArray();
        Array.Sort(arr);
        int mid = arr.Length / 2;
        return (arr.Length % 2 == 1) ? arr[mid] : 0.5 * (arr[mid - 1] + arr[mid]);
    }

    static double StdDev(List<double> vals) {
        if (vals.Count < 2) return 0;
        double mean = vals.Average();
        double sum = 0;
        for (int i = 0; i < vals.Count; i++) { double d = vals[i] - mean; sum += d * d; }
        return Math.Sqrt(sum / (vals.Count - 1));
    }

    static int NearestIndex(double[] axis, double val) {
        int best = 0;
        double bestDist = Math.Abs(axis[0] - val);
        for (int i = 1; i < axis.Length; i++) {
            double d = Math.Abs(axis[i] - val);
            if (d < bestDist) { bestDist = d; best = i; }
        }
        return best;
    }

    static void PrintTable(DynamicTableModel tbl, string title) {
        if (tbl == null || tbl.Values == null) return;
        Console.WriteLine();
        Console.WriteLine(string.Format("--- {0} ({1} x {2}) [X={3}, Y={4}] ---",
            title, tbl.XAxis.Length, tbl.YAxis.Length, AxisSourceName(tbl.XSrc), AxisSourceName(tbl.YSrc)));
        var sb = new StringBuilder();
        sb.Append(string.Format("{0,8} |", "Y \\ X"));
        for (int x = 0; x < tbl.XAxis.Length; x++) sb.Append(string.Format(" {0,6:0.#}", tbl.XAxis[x]));
        Console.WriteLine(sb.ToString());
        Console.WriteLine(new string('-', 10 + tbl.XAxis.Length * 7));
        for (int y = tbl.YAxis.Length - 1; y >= 0; y--) {
            sb.Clear();
            sb.Append(string.Format("{0,8:0.#} |", tbl.YAxis[y]));
            for (int x = 0; x < tbl.XAxis.Length; x++) sb.Append(string.Format(" {0,6:0.##}", tbl.Values[y, x]));
            Console.WriteLine(sb.ToString());
        }
    }

    static void AuditTune(TuneModel tune, bool dumpTables) {
        Console.WriteLine("================================================================");
        Console.WriteLine("MAXXECU CALIBRATION AUDIT (.MaxxECU-save)");
        Console.WriteLine("================================================================");
        Console.WriteLine("Source           : " + tune.SourceName);
        if (tune.FileInfo.Count > 0) {
            string hw, fw, sw, ser, edit;
            tune.FileInfo.TryGetValue("EcuHWType", out hw);
            tune.FileInfo.TryGetValue("ECUFWVersion", out fw);
            tune.FileInfo.TryGetValue("Softwareversion", out sw);
            tune.FileInfo.TryGetValue("ECUSerial", out ser);
            tune.FileInfo.TryGetValue("Edittime", out edit);
            Console.WriteLine(string.Format("ECU Hardware     : {0} | FW: {1} | MTune: {2} | Serial: {3}", hw ?? "?", fw ?? "?", sw ?? "?", ser ?? "?"));
            Console.WriteLine("Last Edited      : " + (edit ?? "?"));
        }

        int cyls = (int)tune.GetSettingDouble("Engine Cylcount", 0);
        double cc = tune.GetSettingDouble("Engine Volume", 0);
        double injFlow = tune.GetSettingDouble("Fuel Injflow", 0);
        double stoich = tune.GetSettingDouble("Fuel StoichAFR", 147) / 10.0;
        int multLam = (int)tune.GetSettingDouble("Multiply Lambda", 0);
        int dualBank = (int)tune.GetSettingDouble("O2 Dual bank", 0);
        int fpAdj = (int)tune.GetSettingDouble("Fuel pressureadj", 0);
        int fpSrc = (int)tune.GetSettingDouble("Primary Injectors FuelPressure Source", 0);

        var fireOrder = new List<int>();
        for (int i = 1; i <= Math.Min(12, cyls); i++) {
            int f = (int)tune.GetSettingDouble("Engine Fireorder " + i, 255);
            if (f != 255) fireOrder.Add(f + 1);
        }

        Console.WriteLine(string.Format("Engine           : {0} cyl | {1:0} cc ({2:0.00} L) | Firing Order: {3}",
            cyls, cc, cc / 1000.0, fireOrder.Count > 0 ? string.Join("-", fireOrder) : "N/A"));
        Console.WriteLine(string.Format("Fueling          : Inj={0:0} cc/min | Stoich={1:0.0} | MultiplyLambda={2} | DualBankO2={3} | FuelPressAdj={4} (Src={5})",
            injFlow, stoich, multLam, dualBank, fpAdj, fpSrc));
        Console.WriteLine("Inj Deadtime (ms): " + tune.GetSetting("Fuel Injdeadtime TimePt", "N/A") + " @ V=" + tune.GetSetting("Fuel Injdeadtime BattVPt", "N/A"));
        Console.WriteLine(string.Format("Closed-Loop O2   : Type={0} | MinCLT={1} C | MinRuntime={2} s | Gain={3} | MaxTPSDelta={4} | MaxMAPDelta={5}",
            tune.GetSetting("Lambdareg Type", "?"),
            tune.GetSetting("Lambdareg MinCLT", "?"),
            tune.GetSetting("Lambdareg MinRuntime", "?"),
            tune.GetSetting("Lambdareg WB Gain", "?"),
            tune.GetSetting("Lambdareg Max TPS Delta", "?"),
            tune.GetSetting("Lambdareg Max MAP Delta", "?")));
        Console.WriteLine(string.Format("Protections      : RevLimit={0} RPM (Type={1}) | BoostCut={2} @ {3} kPa | LeanCut={4} (UseLamTbl={5}, Dev={6}, MinMAP={7}, MinRPM={8})",
            tune.GetSetting("Revlimit RPM", "?"),
            tune.GetSetting("Revlimit Type", "?"),
            tune.GetSetting("BoostCut Enable", "0"),
            tune.GetSetting("BoostCut MAP level", "?"),
            tune.GetSetting("LeanPowerCut Enable", "0"),
            tune.GetSetting("Leancut Use LambdaTable", "0"),
            tune.GetSetting("Leancut LambdaTable Deviation", "?"),
            tune.GetSetting("LeanPowerCut Min MAP", "?"),
            tune.GetSetting("LeanPowerCut Min RPM", "?")));
        Console.WriteLine(string.Format("Knock Control    : Enable={0} | RetardEnable={1} | Bore={2} mm | MaxRet={3} deg | Step={4} deg",
            tune.GetSetting("KnockCtrl Enable", "0"),
            tune.GetSetting("KnockCtrl Retard Enable", "0"),
            tune.GetSetting("KnockCtrl Diameter", "?"),
            tune.GetSetting("KnockCtrl Retard MaxRet", "?"),
            tune.GetSetting("KnockCtrl Retard RetStep", "?")));
        Console.WriteLine(string.Format("Idle / Overrun   : IdleCL={0} | IgnIdleLock={1} (MaxTPS={2}, MaxMAP={3}, MaxRPM={4}) | OverrunCut={5} (MaxTPS={6}, MaxMAP={7})",
            tune.GetSetting("Idle ClosedLoop Enable", "0"),
            tune.GetSetting("Ign Idlelock Enable", "0"),
            tune.GetSetting("Ign Idlelock MaxTPS", "?"),
            tune.GetSetting("Ign Idlelock MaxMAP", "?"),
            tune.GetSetting("Ign Idlelock MaxRPM", "?"),
            tune.GetSetting("OverrunFuelCut Enable", "0"),
            tune.GetSetting("OverrunFuelCut MaxTPS", "?"),
            tune.GetSetting("OverrunFuelCut MaxMAP", "?")));

        Console.WriteLine();
        Console.WriteLine("--- Automated Calibration Checks ---");
        var findings = new List<string>();
        if (multLam != 1) findings.Add("[WARN] Multiply Lambda is OFF (0). Changing Target Lambda table will NOT scale fuel automatically.");
        double minCltLam = tune.GetSettingDouble("Lambdareg MinCLT", 50);
        if (minCltLam < 40) findings.Add(string.Format("[WARN] Lambdareg MinCLT = {0:0.#} C is very low; closed-loop O2 may fight cold warmup enrichment (recommend 45-60 C).", minCltLam));

        DynamicTableModel veTbl, lamTbl, ignTbl, iatTbl;
        if (tune.Tables.TryGetValue("VE Table 1 data", out veTbl) && veTbl.Values != null) {
            int clipped100 = 0, totalCells = veTbl.XAxis.Length * veTbl.YAxis.Length;
            double minVe = double.MaxValue, maxVe = double.MinValue, maxJump = 0;
            string jumpLoc = "";
            for (int y = 0; y < veTbl.YAxis.Length; y++) {
                for (int x = 0; x < veTbl.XAxis.Length; x++) {
                    double v = veTbl.Values[y, x];
                    if (v < minVe) minVe = v;
                    if (v > maxVe) maxVe = v;
                    if (Math.Abs(v - 100.0) < 0.001) clipped100++;
                    if (x > 0) {
                        double d = Math.Abs(v - veTbl.Values[y, x - 1]);
                        if (d > maxJump) { maxJump = d; jumpLoc = string.Format("RPM {0:0}->{1:0} @ Y={2:0.#} ({3:0.#}->{4:0.#})", veTbl.XAxis[x - 1], veTbl.XAxis[x], veTbl.YAxis[y], veTbl.Values[y, x - 1], v); }
                    }
                    if (y > 0) {
                        double d = Math.Abs(v - veTbl.Values[y - 1, x]);
                        if (d > maxJump) { maxJump = d; jumpLoc = string.Format("Y {0:0.#}->{1:0.#} @ RPM={2:0} ({3:0.#}->{4:0.#})", veTbl.YAxis[y - 1], veTbl.YAxis[y], veTbl.XAxis[x], veTbl.Values[y - 1, x], v); }
                    }
                }
            }
            Console.WriteLine(string.Format("VE Table 1       : {0}x{1} | X={2} ({3:0}..{4:0}) | Y={5} ({6:0.#}..{7:0.#}) | Range={8:0.#}..{9:0.#}%",
                veTbl.XAxis.Length, veTbl.YAxis.Length, AxisSourceName(veTbl.XSrc), veTbl.XAxis[0], veTbl.XAxis[veTbl.XAxis.Length - 1],
                AxisSourceName(veTbl.YSrc), veTbl.YAxis[0], veTbl.YAxis[veTbl.YAxis.Length - 1], minVe, maxVe));
            if (clipped100 >= 4 && Math.Abs(maxVe - 100.0) < 0.01) {
                findings.Add(string.Format("[WARN] VE Table 1 has {0}/{1} cells plateaued at exactly 100.0% (possible ceiling clip at high RPM/load; verify WOT Lambda!).", clipped100, totalCells));
            }
            if (maxJump >= 10.0) findings.Add(string.Format("[INFO] Largest adjacent VE Table 1 step is {0:0.0}% at {1}.", maxJump, jumpLoc));
            if (veTbl.YAxis[veTbl.YAxis.Length - 1] <= 105.0) {
                findings.Add(string.Format("[INFO] VE Table 1 top load axis is {0:0.#} kPa (Naturally Aspirated scaling).", veTbl.YAxis[veTbl.YAxis.Length - 1]));
            }
        }

        if (tune.Tables.TryGetValue("Lambda Table 1 data", out lamTbl) && lamTbl.Values != null) {
            double minL = double.MaxValue, maxL = double.MinValue, maxHighLoadL = 0;
            string hlLoc = "";
            for (int y = 0; y < lamTbl.YAxis.Length; y++) {
                for (int x = 0; x < lamTbl.XAxis.Length; x++) {
                    double v = lamTbl.Values[y, x];
                    if (v < minL) minL = v;
                    if (v > maxL) maxL = v;
                    if (lamTbl.YAxis[y] >= 90.0 && v > maxHighLoadL) { maxHighLoadL = v; hlLoc = string.Format("RPM={0:0}, Y={1:0.#}", lamTbl.XAxis[x], lamTbl.YAxis[y]); }
                }
            }
            Console.WriteLine(string.Format("Lambda Table 1   : {0}x{1} | Range={2:0.000}..{3:0.000} | Max Lambda >=90kPa: {4:0.000} ({5})",
                lamTbl.XAxis.Length, lamTbl.YAxis.Length, minL, maxL, maxHighLoadL, hlLoc));
            if (maxHighLoadL > 0.90) findings.Add(string.Format("[WARN] Lambda Table 1 targets {0:0.000} (lean for high load) at {1}.", maxHighLoadL, hlLoc));
        }

        if (tune.Tables.TryGetValue("IgnAdv Table 1 data", out ignTbl) && ignTbl.Values != null) {
            double minI = double.MaxValue, maxI = double.MinValue, maxWotI = double.MinValue;
            string wotLoc = "";
            for (int y = 0; y < ignTbl.YAxis.Length; y++) {
                for (int x = 0; x < ignTbl.XAxis.Length; x++) {
                    double v = ignTbl.Values[y, x];
                    if (v < minI) minI = v;
                    if (v > maxI) maxI = v;
                    if (ignTbl.YAxis[y] >= 90.0 && v > maxWotI) { maxWotI = v; wotLoc = string.Format("RPM={0:0}, Y={1:0.#}", ignTbl.XAxis[x], ignTbl.YAxis[y]); }
                }
            }
            Console.WriteLine(string.Format("IgnAdv Table 1   : {0}x{1} | Range={2:0.#}..{3:0.#} deg | Peak >=90kPa: {4:0.#} deg ({5})",
                ignTbl.XAxis.Length, ignTbl.YAxis.Length, minI, maxI, maxWotI, wotLoc));
        }

        if (tune.Tables.TryGetValue("Fuel IATCorr Table data", out iatTbl) && iatTbl.Values != null && iatTbl.XAxis.Length >= 3) {
            for (int x = 1; x < iatTbl.XAxis.Length - 1; x++) {
                double prev = iatTbl.Values[0, x - 1], cur = iatTbl.Values[0, x], next = iatTbl.Values[0, x + 1];
                if ((cur > prev + 1.5 && cur > next + 1.5) || (cur < prev - 1.5 && cur < next - 1.5)) {
                    findings.Add(string.Format("[WARN] Fuel IATCorr Table has a non-monotonic spike at {0:0.#} C: {1:0.#}% -> {2:0.#}% -> {3:0.#}% (likely typo).",
                        iatTbl.XAxis[x], prev, cur, next));
                }
            }
        }

        if (findings.Count == 0) Console.WriteLine("[OK] No obvious structural calibration anomalies detected.");
        else foreach (var f in findings) Console.WriteLine(f);

        if (dumpTables) {
            if (veTbl != null) PrintTable(veTbl, "VE Table 1");
            if (lamTbl != null) PrintTable(lamTbl, "Lambda Table 1");
            if (ignTbl != null) PrintTable(ignTbl, "IgnAdv Table 1");
        }
    }

    public static void Run(string path, string tunePath, double minClt, double maxDTps, double maxDMap, int minHits, double applyFactor, int lambdaOffsetMs, bool dumpTables, string exportVeTable, string exportCsv) {
        TuneModel tune = null;
        LogModel log = null;
        double metaLogRate = 0.0;

        // Peek first 4 bytes to detect ZIP or GZip without reading 73MB into RAM
        byte[] magic = new byte[4];
        using (var fs = File.OpenRead(path)) { fs.Read(magic, 0, 4); }
        bool isZip = magic[0] == 0x50 && magic[1] == 0x4B && (magic[2] == 0x03 || magic[2] == 0x05);

        if (isZip) {
            using (var za = ZipFile.OpenRead(path)) {
                // Pass 1: read tune & metadata first
                ZipArchiveEntry logEntry = null;
                foreach (var entry in za.Entries) {
                    if (entry.Length == 0) continue;
                    string en = entry.FullName.ToLowerInvariant();
                    if (en.EndsWith(".maxxecu-save") || en.EndsWith(".xml")) {
                        using (var es = entry.Open())
                        using (var ms = new MemoryStream()) {
                            es.CopyTo(ms);
                            tune = ParseTuneXml(ReadTextSmart(ms.ToArray()), Path.GetFileName(path) + "::" + entry.FullName);
                        }
                    } else if (en.EndsWith(".logmetadata")) {
                        using (var es = entry.Open())
                        using (var sr = new StreamReader(es)) {
                            string mTxt = sr.ReadToEnd();
                            var m = Regex.Match(mTxt, @"LogRate\s*=\s*([0-9\.]+)", RegexOptions.IgnoreCase);
                            if (m.Success) metaLogRate = ParseInv(m.Groups[1].Value);
                        }
                    } else if (en.EndsWith(".maxxecu-log") || en.EndsWith(".maxxlog") || en.EndsWith(".csv")) {
                        if (logEntry == null || entry.Length > logEntry.Length) logEntry = entry;
                    }
                }
                // Pass 2: stream log entry
                if (logEntry != null) {
                    int veYSrc = 0;
                    DynamicTableModel vt;
                    if (tune != null && tune.Tables.TryGetValue("VE Table 1 data", out vt)) veYSrc = vt.YSrc;
                    bool isBin;
                    using (var esCheck = logEntry.Open()) { isBin = LooksBinaryStream(esCheck); }
                    if (isBin) {
                        Console.WriteLine("[ERROR] Embedded log '" + logEntry.FullName + "' appears binary. Export to CSV from MTune Log Viewer.");
                    } else {
                        using (var es = logEntry.Open()) {
                            log = ParseLogStream(es, Path.GetFileName(path) + "::" + logEntry.FullName, metaLogRate, veYSrc);
                        }
                    }
                }
            }
        } else {
            // Standalone file
            if (!string.IsNullOrEmpty(tunePath)) {
                tune = ParseTuneXml(ReadTextSmart(File.ReadAllBytes(tunePath)), Path.GetFileName(tunePath));
            }
            bool isGz = magic[0] == 0x1F && magic[1] == 0x8B;
            if (isGz) {
                using (var fs = File.OpenRead(path))
                using (var gz = new GZipStream(fs, CompressionMode.Decompress))
                using (var ms = new MemoryStream()) {
                    gz.CopyTo(ms);
                    byte[] raw = ms.ToArray();
                    string txt = ReadTextSmart(raw);
                    if (txt.TrimStart().StartsWith("<?xml") || txt.TrimStart().StartsWith("<MaxxECUSettingsFile")) {
                        tune = ParseTuneXml(txt, Path.GetFileName(path));
                    } else {
                        int veYSrc = 0; DynamicTableModel vt;
                        if (tune != null && tune.Tables.TryGetValue("VE Table 1 data", out vt)) veYSrc = vt.YSrc;
                        using (var sms = new MemoryStream(raw)) {
                            log = ParseLogStream(sms, Path.GetFileName(path), 0.0, veYSrc);
                        }
                    }
                }
            } else {
                bool isBin;
                using (var fs = File.OpenRead(path)) { isBin = LooksBinaryStream(fs); }
                if (isBin) {
                    Console.WriteLine("================================================================");
                    Console.WriteLine("[UNSUPPORTED BINARY LOG DETECTED]");
                    Console.WriteLine("File: " + path);
                    Console.WriteLine("In MaxxECU MTune: open the log in Log Viewer -> Export -> CSV (or save as .MaxxECU-Zip-log), then re-run.");
                    Console.WriteLine("================================================================");
                    return;
                }
                string head;
                using (var sr = new StreamReader(path, Encoding.UTF8, true)) {
                    char[] cb = new char[256];
                    int n = sr.Read(cb, 0, cb.Length);
                    head = new string(cb, 0, n).TrimStart();
                }
                if (head.StartsWith("<?xml") || head.StartsWith("<MaxxECUSettingsFile")) {
                    tune = ParseTuneXml(ReadTextSmart(File.ReadAllBytes(path)), Path.GetFileName(path));
                } else {
                    int veYSrc = 0; DynamicTableModel vt;
                    if (tune != null && tune.Tables.TryGetValue("VE Table 1 data", out vt)) veYSrc = vt.YSrc;
                    using (var fs = File.OpenRead(path)) {
                        log = ParseLogStream(fs, Path.GetFileName(path), 0.0, veYSrc);
                    }
                }
            }
        }

        if (!string.IsNullOrEmpty(tunePath) && tune == null) {
            tune = ParseTuneXml(ReadTextSmart(File.ReadAllBytes(tunePath)), Path.GetFileName(tunePath));
        }

        if (tune != null) AuditTune(tune, dumpTables);

        if (log == null) {
            if (tune != null) {
                Console.WriteLine();
                Console.WriteLine("[NOTE] Calibration-only input (.MaxxECU-save). No datalog rows were present.");
                Console.WriteLine("Provide a .MaxxECU-Zip-log, .MaxxECU-log, or MTune CSV export for full log analysis.");
            }
            return;
        }

        AnalyzeLog(log, tune, minClt, maxDTps, maxDMap, minHits, applyFactor, lambdaOffsetMs, exportVeTable, exportCsv);
    }

    static void AnalyzeLog(LogModel log, TuneModel tune, double minClt, double maxDTps, double maxDMap, int minHits, double applyFactor, int lambdaOffsetMs, string exportVeTable, string exportCsv) {
        Console.WriteLine();
        Console.WriteLine("================================================================");
        Console.WriteLine("MAXXECU DATALOG ANALYSIS");
        Console.WriteLine("================================================================");
        Console.WriteLine(string.Format("Log Source       : {0} | Rows: {1} | RawCols: {2} (Tracked: {3}) | Delim: '{4}'",
            log.SourceName, log.RowCount, log.TotalRawColumns, log.KeptCols.Count, log.Delimiter == '\t' ? "\\t" : log.Delimiter.ToString()));

        if (log.RowCount < 5) { Console.WriteLine("[WARN] Too few rows to analyze."); return; }

        int cTime = log.GetKept("TIME");
        int cRuntime = log.GetKept("RUNTIME");
        int cRpm = log.GetKept("RPM");
        int cMap = log.GetKept("MAP");
        int cVeLoad = log.GetKept("VE_LOAD");
        int cBaro = log.GetKept("BARO");
        int cTps = log.GetKept("TPS");
        int cLam = log.GetKept("LAMBDA");
        int cLamA = log.GetKept("LAMBDA_A");
        int cLamB = log.GetKept("LAMBDA_B");
        int cLamTgt = log.GetKept("LAMBDA_TGT");
        int cLamCorr = log.GetKept("LAMBDA_CORR");
        int cLamCorrA = log.GetKept("LAMBDA_CORR_A");
        int cLamCorrB = log.GetKept("LAMBDA_CORR_B");
        int cLamState = log.GetKept("LAMBDA_STATE");
        int cLtft = log.GetKept("LTFT");
        int cTotErr = log.GetKept("TOT_FUEL_ERR");
        int cFuelErrA = log.GetKept("FUEL_ERR_A");
        int cFuelErrB = log.GetKept("FUEL_ERR_B");
        int cInjPw = log.GetKept("INJ_PW");
        int cIdc = log.GetKept("IDC");
        int cAccEnr = log.GetKept("ACCEL_ENRICH");
        int cFuelCut = log.GetKept("FUEL_CUT");
        int cFuelCutRsn = log.GetKept("FUEL_CUT_REASON");
        int cIgn = log.GetKept("IGN_ANGLE");
        int cIgnCut = log.GetKept("IGN_CUT");
        int cIgnCutRsn = log.GetKept("IGN_CUT_REASON");
        int cKnockRet = log.GetKept("KNOCK_RETARD");
        int cKnockCnt = log.GetKept("KNOCK_COUNT");
        int cKnockPk = log.GetKept("KNOCK_PEAK");
        int cClt = log.GetKept("CLT");
        int cIat = log.GetKept("IAT");
        int cBatt = log.GetKept("BATT_V");
        int cEth = log.GetKept("ETHANOL");
        int cFuelP = log.GetKept("FUEL_PRESS");
        int cOilP = log.GetKept("OIL_PRESS");
        int cBoostTgt = log.GetKept("BOOST_TGT");
        int cBoostDuty = log.GetKept("BOOST_DUTY");
        int cIdleAir = log.GetKept("IDLE_AIR");
        int cIdleTgt = log.GetKept("IDLE_TGT_RPM");
        int cVss = log.GetKept("VSS");
        int cGear = log.GetKept("GEAR");
        int cTcc = log.GetKept("TCC_STATUS");
        int cTransSlip = log.GetKept("TRANS_SLIP");
        int cErrCnt = log.GetKept("ERR_COUNT");
        int cLastErr = log.GetKept("LAST_ERR");
        int cInSync = log.GetKept("IN_SYNC");

        // Channel Inventory (tracked channels with data)
        Console.WriteLine();
        Console.WriteLine("--- Tracked Channel Inventory ---");
        Console.WriteLine(string.Format("{0,4} | {1,-28} | {2,4} | {3,-6} | {4,9} | {5,9} | {6,9} | {7}",
            "Col", "Name", "ID", "Unit", "Min", "Median", "Max", "Role"));
        Console.WriteLine(new string('-', 98));
        for (int k = 0; k < log.KeptCols.Count; k++) {
            var arr = log.Columns[k];
            var valid = new List<double>();
            for (int r = 0; r < arr.Length; r++) if (!double.IsNaN(arr[r])) valid.Add(arr[r]);
            if (valid.Count == 0) continue;
            var cm = log.KeptCols[k];
            string nm = cm.CleanName.Length > 28 ? cm.CleanName.Substring(0, 28) : cm.CleanName;
            string un = cm.Unit.Length > 6 ? cm.Unit.Substring(0, 6) : cm.Unit;
            string idStr = cm.ChannelId >= 0 ? cm.ChannelId.ToString() : "-";
            Console.WriteLine(string.Format("{0,4} | {1,-28} | {2,4} | {3,-6} | {4,9:0.##} | {5,9:0.##} | {6,9:0.##} | {7}",
                cm.RawIndex, nm, idStr, un, valid.Min(), Median(valid), valid.Max(), cm.Role));
        }

        // Unit normalization
        bool mapIsPsi = (cMap >= 0) && (log.KeptCols[cMap].Unit.IndexOf("psi", StringComparison.OrdinalIgnoreCase) >= 0);
        bool mapIsBar = (cMap >= 0) && (log.KeptCols[cMap].Unit.IndexOf("bar", StringComparison.OrdinalIgnoreCase) >= 0);
        bool cltIsF = (cClt >= 0) && (log.KeptCols[cClt].Unit.IndexOf("F", StringComparison.OrdinalIgnoreCase) >= 0 || log.Columns[cClt].Where(v => !double.IsNaN(v)).DefaultIfEmpty(0).Max() > 140.0);
        bool iatIsF = (cIat >= 0) && (log.KeptCols[cIat].Unit.IndexOf("F", StringComparison.OrdinalIgnoreCase) >= 0 || log.Columns[cIat].Where(v => !double.IsNaN(v)).DefaultIfEmpty(0).Max() > 130.0);
        double stoichDiv = (tune != null) ? (tune.GetSettingDouble("Fuel StoichAFR", 147) / 10.0) : 14.7;

        // Determine time step / time axis
        double dt = (log.MetaLogRate > 0.0005 && log.MetaLogRate < 5.0) ? log.MetaLogRate : 0.05;
        bool hasMonotonicTime = false;
        if (cTime >= 0) {
            double firstT = log.Columns[cTime][0], lastT = log.Columns[cTime][log.RowCount - 1];
            if (!double.IsNaN(firstT) && !double.IsNaN(lastT) && lastT > firstT) {
                hasMonotonicTime = true;
                dt = (lastT - firstT) / Math.Max(1, log.RowCount - 1);
            }
        }
        if (!hasMonotonicTime && log.MetaLogRate <= 0 && cRuntime >= 0) {
            // Estimate dt from engine runtime delta where running
            int rStart = -1, rEnd = -1;
            for (int r = 0; r < log.RowCount; r++) {
                double rt = log.Columns[cRuntime][r];
                if (!double.IsNaN(rt) && rt > 1.0) {
                    if (rStart < 0) rStart = r;
                    if (rt > log.Columns[cRuntime][rStart] + 5.0) { rEnd = r; break; }
                }
            }
            if (rStart >= 0 && rEnd > rStart) {
                dt = (log.Columns[cRuntime][rEnd] - log.Columns[cRuntime][rStart]) / (rEnd - rStart);
            }
        }

        Func<int, double> getTime = r => hasMonotonicTime ? log.Columns[cTime][r] : r * dt;
        Func<int, double> getRpm = r => (cRpm >= 0) ? log.Columns[cRpm][r] : double.NaN;
        Func<int, double> getMapKpa = r => {
            if (cMap < 0) return double.NaN;
            double v = log.Columns[cMap][r];
            if (mapIsPsi) return (v + 14.696) * 6.89476;
            if (mapIsBar) return (v < 0.5 ? v + 1.01325 : v) * 100.0;
            return v;
        };
        Func<int, double> getTps = r => (cTps >= 0) ? log.Columns[cTps][r] : double.NaN;
        Func<int, double> getCltC = r => {
            if (cClt < 0) return 85.0;
            double v = log.Columns[cClt][r];
            return cltIsF ? (v - 32.0) * 5.0 / 9.0 : v;
        };
        Func<int, double> getIatC = r => {
            if (cIat < 0) return double.NaN;
            double v = log.Columns[cIat][r];
            return iatIsF ? (v - 32.0) * 5.0 / 9.0 : v;
        };
        Func<int, int, double> getLamFromCol = (col, r) => {
            if (col < 0) return double.NaN;
            double v = log.Columns[col][r];
            if (double.IsNaN(v)) return double.NaN;
            return (v > 4.0) ? v / stoichDiv : v;
        };
        Func<int, double> getLamEffective = r => {
            double l = getLamFromCol(cLam, r);
            if (!double.IsNaN(l) && l > 0.3) return l;
            double la = getLamFromCol(cLamA, r);
            double lb = getLamFromCol(cLamB, r);
            if (!double.IsNaN(la) && !double.IsNaN(lb) && la > 0.3 && lb > 0.3) return 0.5 * (la + lb);
            return (!double.IsNaN(la) && la > 0.3) ? la : lb;
        };
        Func<int, double> getLamCorrEffective = r => {
            if (cLamCorr >= 0 && !double.IsNaN(log.Columns[cLamCorr][r])) return log.Columns[cLamCorr][r];
            double ca = (cLamCorrA >= 0) ? log.Columns[cLamCorrA][r] : double.NaN;
            double cb = (cLamCorrB >= 0) ? log.Columns[cLamCorrB][r] : double.NaN;
            if (!double.IsNaN(ca) && !double.IsNaN(cb)) return 0.5 * (ca + cb);
            if (!double.IsNaN(ca)) return ca;
            if (!double.IsNaN(cb)) return cb;
            return 0.0;
        };

        double duration = getTime(log.RowCount - 1) - getTime(0);
        double sampleHz = (dt > 0) ? 1.0 / dt : 20.0;
        int offsetRows = (lambdaOffsetMs > 0) ? (int)Math.Round(lambdaOffsetMs / 1000.0 * sampleHz) : 0;

        Console.WriteLine();
        Console.WriteLine("--- Session Summary ---");
        Console.WriteLine(string.Format("Duration         : {0:0.0} s ({1:0.0} min) @ {2:0.0} Hz | Lambda Delay Shift: {3} ms ({4} rows)",
            duration, duration / 60.0, sampleHz, lambdaOffsetMs, offsetRows));

        DynamicTableModel veTbl = null, lamTbl = null;
        if (tune != null) {
            tune.Tables.TryGetValue("VE Table 1 data", out veTbl);
            tune.Tables.TryGetValue("Lambda Table 1 data", out lamTbl);
        }

        bool useTpsLoad = (veTbl != null && veTbl.YSrc == 19);
        double[] xAxis = (veTbl != null && veTbl.XAxis.Length > 1)
            ? veTbl.XAxis
            : new double[] { 800, 1200, 1600, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500, 7000 };
        double[] yAxis = (veTbl != null && veTbl.YAxis.Length > 1)
            ? veTbl.YAxis
            : new double[] { 20, 30, 40, 50, 60, 70, 80, 90, 100, 120, 140, 160, 180, 200, 220 };

        int nx = xAxis.Length, ny = yAxis.Length;
        var cellErrs = new List<double>[ny, nx];
        var cellCorrs = new List<double>[ny, nx];
        var cellSplits = new List<double>[ny, nx];
        for (int y = 0; y < ny; y++)
            for (int x = 0; x < nx; x++) {
                cellErrs[y, x] = new List<double>();
                cellCorrs[y, x] = new List<double>();
                cellSplits[y, x] = new List<double>();
            }

        int runningRows = 0, idleRows = 0, cruiseRows = 0, wotRows = 0, decelRows = 0, steadyRows = 0;
        int fuelCutRows = 0, ignCutRows = 0, syncLossEvents = 0;
        var fuelCutReasons = new HashSet<int>();
        var ignCutReasons = new HashSet<int>();
        var idleRpms = new List<double>();
        var idleTgtRpms = new List<double>();
        var idleMaps = new List<double>();
        var idleIgns = new List<double>();
        var idleLams = new List<double>();
        var idleAirs = new List<double>();
        var knockEvents = new List<string>();
        var fuelPressIdle = new List<double>();
        var fuelPressWot = new List<double>();
        var diffFuelPressWot = new List<double>();

        double maxIdc = 0; int maxIdcRow = -1;
        double minBattRun = 99, maxBattRun = 0, minOilRun = 9999, maxIat = -99, maxClt = -99, maxMap = 0, maxRpm = 0, maxVss = 0;
        double maxKnockRet = 0, maxKnockCnt = 0;
        double maxErrCnt = 0, lastErrCode = 0;

        double[] compTotErr = new double[log.RowCount];
        double[] compIdc = new double[log.RowCount];
        int[] compSteady = new int[log.RowCount];

        var wotPullRanges = new List<int[]>();
        int pullStart = -1;
        bool prevRunning = false;

        for (int r = 0; r < log.RowCount; r++) {
            double rpm = getRpm(r);
            double map = getMapKpa(r);
            double tps = getTps(r);
            double clt = getCltC(r);
            double iat = getIatC(r);
            bool isRunning = !double.IsNaN(rpm) && rpm >= 450;

            if (!double.IsNaN(rpm) && rpm > maxRpm) maxRpm = rpm;
            if (!double.IsNaN(map) && map > maxMap) maxMap = map;
            if (!double.IsNaN(iat) && iat > maxIat) maxIat = iat;
            if (!double.IsNaN(clt) && clt > maxClt) maxClt = clt;
            if (cVss >= 0 && !double.IsNaN(log.Columns[cVss][r]) && log.Columns[cVss][r] > maxVss) maxVss = log.Columns[cVss][r];
            if (cErrCnt >= 0 && !double.IsNaN(log.Columns[cErrCnt][r]) && log.Columns[cErrCnt][r] > maxErrCnt) maxErrCnt = log.Columns[cErrCnt][r];
            if (cLastErr >= 0 && !double.IsNaN(log.Columns[cLastErr][r]) && log.Columns[cLastErr][r] > 0) lastErrCode = log.Columns[cLastErr][r];

            int rLam = Math.Min(log.RowCount - 1, r + offsetRows);
            double lam = getLamEffective(rLam);
            double lamA = getLamFromCol(cLamA, rLam);
            double lamB = getLamFromCol(cLamB, rLam);

            double lamTgt = (cLamTgt >= 0) ? getLamFromCol(cLamTgt, r) : double.NaN;
            if (double.IsNaN(lamTgt) && lamTbl != null && !double.IsNaN(rpm)) {
                double loadForLam = (lamTbl.YSrc == 19) ? tps : map;
                if (!double.IsNaN(loadForLam)) lamTgt = BilinearLookup(lamTbl, rpm, loadForLam);
            }

            double lamCorr = getLamCorrEffective(r);
            double ltft = (cLtft >= 0 && !double.IsNaN(log.Columns[cLtft][r])) ? log.Columns[cLtft][r] : 0.0;

            double totErr = double.NaN;
            if (!double.IsNaN(lam) && !double.IsNaN(lamTgt) && lamTgt > 0.5 && lam > 0.5) {
                totErr = ((1.0 + (lamCorr + ltft) / 100.0) * (lam / lamTgt) - 1.0) * 100.0;
            }
            compTotErr[r] = totErr;

            double idc = double.NaN;
            if (cIdc >= 0 && !double.IsNaN(log.Columns[cIdc][r])) idc = log.Columns[cIdc][r];
            else if (cInjPw >= 0 && !double.IsNaN(log.Columns[cInjPw][r]) && !double.IsNaN(rpm)) idc = (log.Columns[cInjPw][r] * rpm) / 1200.0;
            compIdc[r] = idc;
            if (!double.IsNaN(idc) && idc > maxIdc) { maxIdc = idc; maxIdcRow = r; }

            if (isRunning) {
                runningRows++;
                if (cBatt >= 0 && !double.IsNaN(log.Columns[cBatt][r])) {
                    double bv = log.Columns[cBatt][r];
                    if (bv < minBattRun) minBattRun = bv;
                    if (bv > maxBattRun) maxBattRun = bv;
                }
                if (cOilP >= 0 && !double.IsNaN(log.Columns[cOilP][r]) && log.Columns[cOilP][r] > 0 && log.Columns[cOilP][r] < minOilRun) {
                    minOilRun = log.Columns[cOilP][r];
                }
                if (prevRunning && cInSync >= 0 && !double.IsNaN(log.Columns[cInSync][r]) && log.Columns[cInSync][r] < 0.5) {
                    syncLossEvents++;
                }
            }
            prevRunning = isRunning;

            double kRet = (cKnockRet >= 0 && !double.IsNaN(log.Columns[cKnockRet][r])) ? Math.Abs(log.Columns[cKnockRet][r]) : 0.0;
            if (kRet > maxKnockRet) maxKnockRet = kRet;
            if (cKnockCnt >= 0 && !double.IsNaN(log.Columns[cKnockCnt][r]) && log.Columns[cKnockCnt][r] > maxKnockCnt) maxKnockCnt = log.Columns[cKnockCnt][r];
            if (isRunning && kRet > 0.25 && knockEvents.Count < 40) {
                double ignV = (cIgn >= 0) ? log.Columns[cIgn][r] : double.NaN;
                knockEvents.Add(string.Format("t={0:0.00}s | RPM={1:0} | MAP={2:0.#} | TPS={3:0.#}% | Ign={4:0.#} | Lam={5:0.000} | KnockRet={6:0.##} deg",
                    getTime(r), rpm, map, tps, ignV, lam, kRet));
            }

            bool fuelCutOn = (cFuelCut >= 0 && !double.IsNaN(log.Columns[cFuelCut][r]) && log.Columns[cFuelCut][r] > 0.5);
            bool ignCutOn = (cIgnCut >= 0 && !double.IsNaN(log.Columns[cIgnCut][r]) && log.Columns[cIgnCut][r] > 0.5);
            if (isRunning && fuelCutOn) {
                fuelCutRows++;
                if (cFuelCutRsn >= 0 && !double.IsNaN(log.Columns[cFuelCutRsn][r])) fuelCutReasons.Add((int)log.Columns[cFuelCutRsn][r]);
            }
            if (isRunning && ignCutOn) {
                ignCutRows++;
                if (cIgnCutRsn >= 0 && !double.IsNaN(log.Columns[cIgnCutRsn][r])) ignCutReasons.Add((int)log.Columns[cIgnCutRsn][r]);
            }

            bool isWot = isRunning && ((!double.IsNaN(tps) && tps >= 70.0) || (!double.IsNaN(map) && map >= 92.0 && (double.IsNaN(tps) || tps >= 45.0)));
            bool isIdle = isRunning && rpm <= 1300 && (double.IsNaN(tps) || tps <= 1.2) && (cVss < 0 || double.IsNaN(log.Columns[cVss][r]) || log.Columns[cVss][r] < 5.0);
            bool isDecel = isRunning && rpm > 1300 && (!double.IsNaN(tps) && tps <= 1.0) && (!double.IsNaN(map) && map <= 35.0);

            if (isWot) {
                wotRows++;
                if (cFuelP >= 0 && !double.IsNaN(log.Columns[cFuelP][r]) && log.Columns[cFuelP][r] > 50) {
                    fuelPressWot.Add(log.Columns[cFuelP][r]);
                    if (!double.IsNaN(map)) diffFuelPressWot.Add(log.Columns[cFuelP][r] - map);
                }
                if (pullStart < 0) pullStart = r;
            } else {
                if (pullStart >= 0) {
                    if (getTime(r - 1) - getTime(pullStart) >= 0.4) wotPullRanges.Add(new int[] { pullStart, r - 1 });
                    pullStart = -1;
                }
            }
            if (isIdle) {
                idleRows++;
                idleRpms.Add(rpm);
                if (cIdleTgt >= 0 && !double.IsNaN(log.Columns[cIdleTgt][r])) idleTgtRpms.Add(log.Columns[cIdleTgt][r]);
                if (!double.IsNaN(map)) idleMaps.Add(map);
                if (cIgn >= 0 && !double.IsNaN(log.Columns[cIgn][r])) idleIgns.Add(log.Columns[cIgn][r]);
                if (!double.IsNaN(lam) && lam > 0.5 && lam < 1.5) idleLams.Add(lam);
                if (cIdleAir >= 0 && !double.IsNaN(log.Columns[cIdleAir][r])) idleAirs.Add(log.Columns[cIdleAir][r]);
                if (cFuelP >= 0 && !double.IsNaN(log.Columns[cFuelP][r]) && log.Columns[cFuelP][r] > 50) fuelPressIdle.Add(log.Columns[cFuelP][r]);
            } else if (isDecel) decelRows++;
            else if (isRunning && !isWot) cruiseRows++;

            double dTps = (r > 0 && !double.IsNaN(tps) && !double.IsNaN(getTps(r - 1))) ? Math.Abs(tps - getTps(r - 1)) : 0.0;
            double dMap = (r > 0 && !double.IsNaN(map) && !double.IsNaN(getMapKpa(r - 1))) ? Math.Abs(map - getMapKpa(r - 1)) : 0.0;
            bool accEnrOn = (cAccEnr >= 0 && !double.IsNaN(log.Columns[cAccEnr][r]) && Math.Abs(log.Columns[cAccEnr][r]) > 0.5);

            bool steady = isRunning && !isDecel && !fuelCutOn && !ignCutOn && !accEnrOn
                && clt >= minClt
                && dTps <= maxDTps && dMap <= maxDMap
                && !double.IsNaN(lam) && lam >= 0.65 && lam <= 1.35
                && !double.IsNaN(totErr);

            if (steady) {
                double loadVal = useTpsLoad ? tps : ((cVeLoad >= 0 && !double.IsNaN(log.Columns[cVeLoad][r])) ? log.Columns[cVeLoad][r] : map);
                if (!double.IsNaN(loadVal)) {
                    steadyRows++;
                    compSteady[r] = 1;
                    int ix = NearestIndex(xAxis, rpm);
                    int iy = NearestIndex(yAxis, loadVal);
                    cellErrs[iy, ix].Add(totErr);
                    cellCorrs[iy, ix].Add(lamCorr);
                    if (!double.IsNaN(lamA) && !double.IsNaN(lamB) && lamA > 0.5 && lamB > 0.5) {
                        cellSplits[iy, ix].Add((lamA - lamB) / (0.5 * (lamA + lamB)) * 100.0);
                    }
                }
            }
        }
        if (pullStart >= 0 && getTime(log.RowCount - 1) - getTime(pullStart) >= 0.4) {
            wotPullRanges.Add(new int[] { pullStart, log.RowCount - 1 });
        }

        double denom = Math.Max(1, runningRows);
        Console.WriteLine(string.Format("Engine Running   : {0}/{1} rows ({2:0.#}%) | Idle={3:0.#}% | Cruise={4:0.#}% | Decel={5:0.#}% | HighLoad/WOT={6:0.#}% | SteadyVEHits={7}",
            runningRows, log.RowCount, 100.0 * runningRows / log.RowCount,
            100.0 * idleRows / denom, 100.0 * cruiseRows / denom, 100.0 * decelRows / denom, 100.0 * wotRows / denom, steadyRows));
        Console.WriteLine(string.Format("Peak Envelope    : MaxRPM={0:0} | MaxMAP={1:0.#} kPa | MaxCLT={2:0.#} C | MaxIAT={3:0.#} C | MaxIDC={4:0.#}% | BattRun={5:0.##}..{6:0.##} V",
            maxRpm, maxMap, maxClt, maxIat, maxIdc, minBattRun < 90 ? minBattRun : double.NaN, maxBattRun));
        if (cVss >= 0) Console.WriteLine(string.Format("Vehicle Speed    : MaxVSS={0:0.#}", maxVss));
        if (fuelPressIdle.Count > 0 || fuelPressWot.Count > 0) {
            Console.WriteLine(string.Format("Fuel Pressure    : Idle Median={0:0.#} kPa | WOT Median={1:0.#} kPa (Min={2:0.#}) | WOT Diff(FP-MAP) Min={3:0.#} kPa",
                fuelPressIdle.Count > 0 ? Median(fuelPressIdle) : double.NaN,
                fuelPressWot.Count > 0 ? Median(fuelPressWot) : double.NaN,
                fuelPressWot.Count > 0 ? fuelPressWot.Min() : double.NaN,
                diffFuelPressWot.Count > 0 ? diffFuelPressWot.Min() : double.NaN));
        }
        if (cOilP >= 0 && minOilRun < 9000) Console.WriteLine(string.Format("Oil Pressure     : Min Running = {0:0.#} kPa", minOilRun));
        if (cEth >= 0) {
            var ethVals = log.Columns[cEth].Where(v => !double.IsNaN(v)).ToList();
            if (ethVals.Count > 0 && ethVals.Max() > 0.5) Console.WriteLine(string.Format("Ethanol Content  : Min={0:0.#}% | Median={1:0.#}% | Max={2:0.#}%", ethVals.Min(), Median(ethVals), ethVals.Max()));
        }
        if (maxErrCnt > 0 || syncLossEvents > 0 || fuelCutRows > 0 || ignCutRows > 0) {
            Console.WriteLine(string.Format("Status & Cuts    : ErrCount={0:0} (LastCode={1:0}) | SyncLossEvents={2} | FuelCutRows={3} (Reasons={4}) | IgnCutRows={5} (Reasons={6})",
                maxErrCnt, lastErrCode, syncLossEvents, fuelCutRows, string.Join(",", fuelCutReasons), ignCutRows, string.Join(",", ignCutReasons)));
        }

        // VE Error Histogram
        Console.WriteLine();
        Console.WriteLine(string.Format("--- Steady-State Total VE Error % Histogram (Median | MinHits={0} | Positive=Lean/ADD, Negative=Rich/SUB) ---", minHits));
        var sb = new StringBuilder();
        string yLabel = useTpsLoad ? "TPS\\RPM" : (cVeLoad >= 0 ? "LD\\RPM" : "MAP\\RPM");
        sb.Append(string.Format("{0,7} |", yLabel));
        for (int x = 0; x < nx; x++) sb.Append(string.Format(" {0,7:0}", xAxis[x]));
        Console.WriteLine(sb.ToString());
        Console.WriteLine(new string('-', 9 + nx * 8));

        double[,] newVe = (veTbl != null && veTbl.Values != null) ? (double[,])veTbl.Values.Clone() : null;
        int cellsAdjusted = 0, cellsLowHits = 0;
        var bigErrors = new List<Tuple<double, string>>();

        for (int y = ny - 1; y >= 0; y--) {
            sb.Clear();
            sb.Append(string.Format("{0,7:0.#} |", yAxis[y]));
            for (int x = 0; x < nx; x++) {
                int cnt = cellErrs[y, x].Count;
                if (cnt == 0) {
                    sb.Append("       .");
                } else if (cnt < minHits) {
                    cellsLowHits++;
                    double med = Median(cellErrs[y, x]);
                    sb.Append(string.Format(" ({0,4:+0;-0;0})", med));
                } else {
                    double med = Median(cellErrs[y, x]);
                    sb.Append(string.Format(" {0,6:+0.0;-0.0;0.0}%", med));
                    if (Math.Abs(med) >= 3.0) {
                        string veInfo = (veTbl != null && veTbl.Values != null)
                            ? string.Format(" | VE {0:0.#}->{1:0.#}", veTbl.Values[y, x], Math.Round(veTbl.Values[y, x] * (1.0 + med * ((Math.Abs(med) > 5.0) ? applyFactor : 1.0) / 100.0), 1))
                            : "";
                        bigErrors.Add(Tuple.Create(Math.Abs(med), string.Format("RPM={0,4:0}, Load={1,5:0.#}: Err={2,6:+0.0;-0.0;0.0}% (n={3,4}, CLCorr={4:+0.0;-0.0;0.0}%){5}",
                            xAxis[x], yAxis[y], med, cnt, Median(cellCorrs[y, x]), veInfo)));
                    }
                    if (newVe != null) {
                        double factor = (Math.Abs(med) > 5.0) ? applyFactor : 1.0;
                        double applied = med * factor;
                        newVe[y, x] = Math.Round(newVe[y, x] * (1.0 + applied / 100.0), 1);
                        if (Math.Abs(med) >= 1.0) cellsAdjusted++;
                    }
                }
            }
            Console.WriteLine(sb.ToString());
        }
        Console.WriteLine(string.Format("Cells with >= {0} hits outside +/-3%: {1} | Low-hit cells (<{0}, shown in parens): {2}", minHits, bigErrors.Count, cellsLowHits));

        if (bigErrors.Count > 0) {
            Console.WriteLine();
            Console.WriteLine("Largest Steady-State VE Errors (|err| >= 3%, sorted by magnitude, top 25):");
            foreach (var item in bigErrors.OrderByDescending(t => t.Item1).Take(25)) Console.WriteLine("  " + item.Item2);
        }

        // Dual Bank Split Summary
        if (cLamA >= 0 && cLamB >= 0) {
            var allSplits = new List<double>();
            for (int y = 0; y < ny; y++) for (int x = 0; x < nx; x++) allSplits.AddRange(cellSplits[y, x]);
            if (allSplits.Count > 0) {
                Console.WriteLine();
                Console.WriteLine("--- Dual-Bank Wideband Balance (Bank A vs Bank B) ---");
                Console.WriteLine(string.Format("Steady-State Split (A-B): Median={0:+0.00;-0.00;0.00}% | Mean={1:+0.00;-0.00;0.00}% | Samples={2}",
                    Median(allSplits), allSplits.Average(), allSplits.Count));
            }
        }

        // WOT Pull Analysis
        if (wotPullRanges.Count > 0) {
            Console.WriteLine();
            Console.WriteLine(string.Format("--- WOT / High-Load Pulls Detected: {0} (showing up to 5 longest) ---", wotPullRanges.Count));
            int pIdx = 0;
            foreach (var rng in wotPullRanges.OrderByDescending(r => r[1] - r[0]).Take(5)) {
                pIdx++;
                int s = rng[0], e = rng[1];
                Console.WriteLine(string.Format("Pull #{0}: t={1:0.00}..{2:0.00}s ({3:0.00}s) | RPM {4:0} -> {5:0}",
                    pIdx, getTime(s), getTime(e), getTime(e) - getTime(s), getRpm(s), getRpm(e)));
                Console.WriteLine("  RPM Bin |   MAP |  LamTgt |  Lam A  |  Lam B  | LamCorr |  Ign | KnockR |  IDC% | FuelP |  IAT");
                for (int bin = 1500; bin <= 8000; bin += 500) {
                    var rowsInBin = new List<int>();
                    for (int r = s; r <= e; r++) {
                        double rv = getRpm(r);
                        if (!double.IsNaN(rv) && rv >= bin - 250 && rv < bin + 250) rowsInBin.Add(r);
                    }
                    if (rowsInBin.Count == 0) continue;
                    double bMap = rowsInBin.Select(r => getMapKpa(r)).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    double bLamA = rowsInBin.Select(r => cLamA >= 0 ? getLamFromCol(cLamA, Math.Min(log.RowCount - 1, r + offsetRows)) : getLamEffective(Math.Min(log.RowCount - 1, r + offsetRows))).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    double bLamB = rowsInBin.Select(r => cLamB >= 0 ? getLamFromCol(cLamB, Math.Min(log.RowCount - 1, r + offsetRows)) : double.NaN).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    double bTgt = rowsInBin.Select(r => cLamTgt >= 0 ? getLamFromCol(cLamTgt, r) : (lamTbl != null ? BilinearLookup(lamTbl, getRpm(r), lamTbl.YSrc == 19 ? getTps(r) : getMapKpa(r)) : double.NaN)).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    double bCor = rowsInBin.Select(r => getLamCorrEffective(r)).DefaultIfEmpty(0).Average();
                    double bIgn = rowsInBin.Select(r => cIgn >= 0 ? log.Columns[cIgn][r] : double.NaN).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    double bKnk = rowsInBin.Select(r => cKnockRet >= 0 ? Math.Abs(log.Columns[cKnockRet][r]) : 0.0).DefaultIfEmpty(0).Max();
                    double bIdc = rowsInBin.Select(r => compIdc[r]).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Max();
                    double bFp = rowsInBin.Select(r => cFuelP >= 0 ? log.Columns[cFuelP][r] : double.NaN).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    double bIat = rowsInBin.Select(r => getIatC(r)).Where(v => !double.IsNaN(v)).DefaultIfEmpty(double.NaN).Average();
                    Console.WriteLine(string.Format("  {0,7} | {1,5:0.#} | {2,7:0.000} | {3,7:0.000} | {4,7:0.000} | {5,6:+0.0;-0.0;0.0}% | {6,4:0.#} | {7,6:0.##} | {8,5:0.#} | {9,5:0.#} | {10,4:0.#}",
                        bin, bMap, bTgt, bLamA, bLamB, bCor, bIgn, bKnk, bIdc, bFp, bIat));
                }
            }
        }

        // Transient Tip-In / Accel Enrichment Check
        if (cTps >= 0 && (cLam >= 0 || cLamA >= 0)) {
            var tipIns = new List<string>();
            int winRows = Math.Max(2, (int)Math.Round(0.15 * sampleHz));
            int evalEndRows = Math.Max(4, (int)Math.Round(0.60 * sampleHz));
            int lastTipRow = -evalEndRows;
            for (int r = winRows; r < log.RowCount - evalEndRows; r++) {
                if (r - lastTipRow < evalEndRows) continue;
                double tpsNow = getTps(r), tpsPrev = getTps(r - winRows);
                double rpmNow = getRpm(r);
                if (!double.IsNaN(tpsNow) && !double.IsNaN(tpsPrev) && !double.IsNaN(rpmNow) && rpmNow >= 600 && (tpsNow - tpsPrev) >= 12.0) {
                    lastTipRow = r;
                    double maxLeanDev = -99, maxRichDev = 99;
                    for (int k = r + 1; k <= Math.Min(log.RowCount - 1, r + evalEndRows); k++) {
                        double l = getLamEffective(k);
                        double lt = (cLamTgt >= 0) ? getLamFromCol(cLamTgt, k) : (lamTbl != null ? BilinearLookup(lamTbl, getRpm(k), lamTbl.YSrc == 19 ? getTps(k) : getMapKpa(k)) : double.NaN);
                        if (!double.IsNaN(l) && !double.IsNaN(lt) && l > 0.5 && l < 1.5) {
                            double dev = l - lt;
                            if (dev > maxLeanDev) maxLeanDev = dev;
                            if (dev < maxRichDev) maxRichDev = dev;
                        }
                    }
                    if (maxLeanDev > -50 && tipIns.Count < 12) {
                        tipIns.Add(string.Format("t={0:0.00}s | RPM={1:0} | TPS {2:0.#}%->{3:0.#}% | PeakLeanDev={4:+0.000;-0.000;0.000} | PeakRichDev={5:+0.000;-0.000;0.000}",
                            getTime(r), rpmNow, tpsPrev, tpsNow, maxLeanDev, maxRichDev));
                    }
                }
            }
            if (tipIns.Count > 0) {
                Console.WriteLine();
                Console.WriteLine(string.Format("--- Transient Tip-In / Accel Enrichment Events (first {0}) ---", tipIns.Count));
                foreach (var ti in tipIns) Console.WriteLine("  " + ti);
            }
        }

        // Idle Stability Summary
        if (idleRpms.Count >= 10) {
            Console.WriteLine();
            Console.WriteLine("--- Idle Stability (TPS <= 1.2%, RPM <= 1300, Low Speed) ---");
            Console.WriteLine(string.Format("Samples={0} | RPM: Mean={1:0} StdDev={2:0.#} (Min={3:0}, Max={4:0}) | TargetRPM Median={5:0}",
                idleRpms.Count, idleRpms.Average(), StdDev(idleRpms), idleRpms.Min(), idleRpms.Max(),
                idleTgtRpms.Count > 0 ? Median(idleTgtRpms) : double.NaN));
            if (idleMaps.Count > 0) Console.WriteLine(string.Format("Idle MAP: Mean={0:0.#} kPa (Min={1:0.#}, Max={2:0.#})", idleMaps.Average(), idleMaps.Min(), idleMaps.Max()));
            if (idleIgns.Count > 0) Console.WriteLine(string.Format("Idle Ign: Mean={0:0.#} deg (Min={1:0.#}, Max={2:0.#})", idleIgns.Average(), idleIgns.Min(), idleIgns.Max()));
            if (idleLams.Count > 0) Console.WriteLine(string.Format("Idle Lam: Mean={0:0.000} (Min={1:0.000}, Max={2:0.000})", idleLams.Average(), idleLams.Min(), idleLams.Max()));
            if (idleAirs.Count > 0) Console.WriteLine(string.Format("Idle Air: Mean={0:0.#}% (Min={1:0.#}%, Max={2:0.#}%)", idleAirs.Average(), idleAirs.Min(), idleAirs.Max()));
        }

        // Boost Control Summary
        if (maxMap > 115.0) {
            Console.WriteLine();
            Console.WriteLine("--- Boost Control Summary (MAP > 115 kPa) ---");
            var bErrs = new List<double>();
            double maxDuty = 0;
            for (int r = 0; r < log.RowCount; r++) {
                double m = getMapKpa(r);
                if (!double.IsNaN(m) && m > 115.0) {
                    if (cBoostTgt >= 0 && !double.IsNaN(log.Columns[cBoostTgt][r]) && log.Columns[cBoostTgt][r] > 50) {
                        double bt = log.Columns[cBoostTgt][r];
                        if (mapIsPsi) bt = (bt + 14.696) * 6.89476;
                        bErrs.Add(m - bt);
                    }
                    if (cBoostDuty >= 0 && !double.IsNaN(log.Columns[cBoostDuty][r]) && log.Columns[cBoostDuty][r] > maxDuty) maxDuty = log.Columns[cBoostDuty][r];
                }
            }
            Console.WriteLine(string.Format("Peak MAP={0:0.#} kPa ({1:0.#} psi gauge) | Peak Boost Duty={2:0.#}%",
                maxMap, (maxMap - 101.325) / 6.89476, maxDuty));
            if (bErrs.Count > 0) Console.WriteLine(string.Format("Boost Tracking (Actual - Target): Median={0:+0.#;-0.#;0} kPa | Max Overshoot={1:+0.#;-0.#;0} kPa", Median(bErrs), bErrs.Max()));
        }

        // Knock & Safety Summary
        Console.WriteLine();
        Console.WriteLine("--- Knock & Safety Alerts ---");
        Console.WriteLine(string.Format("Knock Summary    : PeakKnockRetard={0:0.##} deg | MaxKnockCount={1:0}", maxKnockRet, maxKnockCnt));
        if (knockEvents.Count == 0) Console.WriteLine("[OK] No knock retard events > 0.25 deg detected.");
        else {
            Console.WriteLine(string.Format("[WARN] {0} knock retard sample(s) logged (showing up to 15):", knockEvents.Count));
            foreach (var ke in knockEvents.Take(15)) Console.WriteLine("  " + ke);
        }
        if (maxIdc >= 80.0 && maxIdcRow >= 0) {
            Console.WriteLine(string.Format("[WARN] High Injector Duty Cycle: {0:0.#}% at t={1:0.00}s, RPM={2:0}, MAP={3:0.#} kPa",
                maxIdc, getTime(maxIdcRow), getRpm(maxIdcRow), getMapKpa(maxIdcRow)));
        }

        // Exports
        if (!string.IsNullOrEmpty(exportVeTable) && newVe != null) {
            using (var sw = new StreamWriter(exportVeTable, false, Encoding.UTF8)) {
                for (int y = ny - 1; y >= 0; y--) {
                    var vals = new string[nx];
                    for (int x = 0; x < nx; x++) vals[x] = newVe[y, x].ToString("0.0", CultureInfo.InvariantCulture);
                    sw.WriteLine(string.Join("\t", vals));
                }
            }
            Console.WriteLine(string.Format("\n[EXPORTED] Suggested VE Table ({0} cells updated, Y-axis high-to-low) -> {1}", cellsAdjusted, exportVeTable));
        }

        if (!string.IsNullOrEmpty(exportCsv)) {
            using (var sw = new StreamWriter(exportCsv, false, Encoding.UTF8)) {
                var hdrs = log.KeptCols.Select(c => c.CleanName).ToList();
                hdrs.Add("Computed_TotalVeErrorPct");
                hdrs.Add("Computed_IDC_Pct");
                hdrs.Add("Computed_SteadyState");
                sw.WriteLine(string.Join(",", hdrs.Select(h => "\"" + h.Replace("\"", "\"\"") + "\"")));
                for (int r = 0; r < log.RowCount; r++) {
                    var row = new List<string>(log.KeptCols.Count + 3);
                    for (int k = 0; k < log.KeptCols.Count; k++) {
                        double v = log.Columns[k][r];
                        row.Add(double.IsNaN(v) ? "" : v.ToString("G", CultureInfo.InvariantCulture));
                    }
                    row.Add(double.IsNaN(compTotErr[r]) ? "" : compTotErr[r].ToString("0.##", CultureInfo.InvariantCulture));
                    row.Add(double.IsNaN(compIdc[r]) ? "" : compIdc[r].ToString("0.##", CultureInfo.InvariantCulture));
                    row.Add(compSteady[r].ToString(CultureInfo.InvariantCulture));
                    sw.WriteLine(string.Join(",", row));
                }
            }
            Console.WriteLine("[EXPORTED] Normalized CSV -> " + exportCsv);
        }
    }
}
'@

if (-not ([System.Management.Automation.PSTypeName]'MaxxEcuAnalyzerV2').Type) {
    Add-Type -TypeDefinition $csCode -ReferencedAssemblies @('System.Xml', 'System.IO.Compression', 'System.IO.Compression.FileSystem', 'System.Core')
}

[MaxxEcuAnalyzerV2]::Run($Path, $TunePath, $MinClt, $MaxDTps, $MaxDMap, $MinHits, $ApplyFactor, $LambdaOffsetMs, [bool]$DumpTables, $ExportVeTable, $ExportCsv)
