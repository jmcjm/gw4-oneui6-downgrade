#!/usr/bin/env python3
"""Adapts the IYI1 device tree to bootloader rev2 (XXS2JZG3).

The SoC device tree in the boot image is byte for byte the same on the
SM-R870 and the SM-R860, in IYI1 and in JZG3, so one script serves both.

1. The rev2 bootloader applies its own device tree overlay after the DTBO.
   That overlay references the labels log_first and log_kevents_small,
   which the IYI1 device tree does not have, so the bootloader stops with
   "DT Overlay FAIL". Both nodes are added (disabled, so the 4.19 kernel
   ignores them) with their __symbols__ entries.
2. The second core has MPIDR 0x100 on rev2; its cpu node gets that reg,
   and a cpu-map keeps both cores in one cluster.
3. The cpupm node is replaced by the exynos-cpupm node of the rev2 (5.15)
   device tree, which the 5.15 CPUPM driver ported to 4.19 binds to by its
   compatible: cpd_cl0 with cal-id, sicd as a type 2 (system) mode with
   deferred-enabled, and the wakeup-mask node with the SICD wakeup masks
   and their status registers. The values are those of the R870XXS2JZG3
   device tree, which is identical to the R860XXS2JZG3 one.

Usage: patch-dts.py <in.dts> <out.dts>
"""
import re
import sys

NODES = """
\t\t\tlog_first {
\t\t\t\tcompatible = "log_first";
\t\t\t\treg = <0x00 0xa0610000 0x40000>;
\t\t\t\tstatus = "no";
\t\t\t\tphandle = <0x15c>;
\t\t\t};

\t\t\tlog_kevents_small {
\t\t\t\tcompatible = "log_kevents";
\t\t\t\treg = <0x00 0xa0410000 0x3c000>;
\t\t\t\tstatus = "no";
\t\t\t\tphandle = <0x15d>;
\t\t\t};
"""

# exynos-cpupm node of the R870XXS2JZG3 (5.15) device tree, see 3. above
EXYNOS_CPUPM = """\texynos-cpupm {
\t\tcompatible = "samsung,exynos-cpupm";
\t\tstatus = "okay";

\t\tcpd_cl0 {
\t\t\tdevice_type = "cpupm";
\t\t\ttarget-residency = <0xbb8>;
\t\t\tcal-id = <0x00>;
\t\t\ttype = <0x00>;
\t\t\tsiblings = "0-1";
\t\t};

\t\tsicd {
\t\t\tdevice_type = "cpupm";
\t\t\ttarget-residency = <0xbb8>;
\t\t\ttype = <0x02>;
\t\t\tsiblings = "0-1";
\t\t\tentry-allowed = "0-1";
\t\t\tdeferred-enabled;
\t\t};

\t\twakeup-mask {

\t\t\twakeup-masks {

\t\t\t\tmask0 {
\t\t\t\t\tmask-reg-offset = <0x3c44>;
\t\t\t\t\tstat-reg-offset = <0x3c50>;
\t\t\t\t\tmask = <0x3000000>;
\t\t\t\t};

\t\t\t\tmask1 {
\t\t\t\t\tmask-reg-offset = <0x3c64>;
\t\t\t\t\tstat-reg-offset = <0x3c54>;
\t\t\t\t\tmask = <0x00>;
\t\t\t\t};
\t\t\t};

\t\t\teint-wakeup-masks {

\t\t\t\tmask0 {
\t\t\t\t\tmask-reg-offset = <0x60c>;
\t\t\t\t};
\t\t\t};
\t\t};
\t};
"""

SYMBOLS = (
    '\t\tlog_first = "/reserved-memory/debug_snapshot/log_first";\n'
    '\t\tlog_kevents_small = "/reserved-memory/debug_snapshot/log_kevents_small";\n'
)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    dts = open(src).read()

    for label in ("log_first", "log_kevents_small"):
        if re.search(r"^\t\t\t%s \{" % label, dts, re.M):
            sys.exit("%s already present" % label)
    for used in ("0x15c", "0x15d"):
        if re.search(r"phandle = <%s>;" % used, dts):
            sys.exit("phandle %s already used" % used)

    # nodes: after log_arrdumpreset, inside reserved-memory/debug_snapshot
    node = re.compile(r"(\t\t\tlog_arrdumpreset \{\n(?:\t\t\t\t.*\n)*?\t\t\t\};\n)")
    dts, n = node.subn(lambda m: m.group(1) + NODES, dts, count=1)
    if n != 1:
        sys.exit("log_arrdumpreset node not found")

    # symbols: after the log_arrdumppanic entry in __symbols__
    sym = re.compile(r'(\t\tlog_arrdumppanic = "/reserved-memory/debug_snapshot/log_arrdumppanic";\n)')
    dts, n = sym.subn(lambda m: m.group(1) + SYMBOLS, dts, count=1)
    if n != 1:
        sys.exit("log_arrdumppanic symbol not found")

    # second core: on bootloader rev2 its MPIDR is 0x100 (as in the 5.15
    # device tree), not 0x1; with 0x1 PSCI CPU_ON wakes nothing
    cpu1 = re.compile(r"(\t\tcpu@0001 \{\n(?:\t\t\t.*\n)*?\t\t\treg = <0x00 )0x01(>;\n)")
    dts, n = cpu1.subn(lambda m: m.group(1) + "0x100" + m.group(2), dts, count=1)
    if n != 1:
        sys.exit("cpu@0001 with reg <0x00 0x01> not found")

    # Without a cpu-map the kernel takes the topology from MPIDR, and with
    # 0x100 (Aff1 = 1) the second core would form a cluster of its own.
    # Both cores are one cluster, as in the 5.15 device tree.
    if "cpu-map {" in dts:
        sys.exit("cpu-map already present")
    phandles = []
    for name in ("cpu@0000", "cpu@0001"):
        m = re.search(r"\t\t%s \{\n(?:\t\t\t.*\n)*?\t\t\tphandle = <(0x[0-9a-f]+)>;\n" % name, dts)
        if not m:
            sys.exit("no phandle for %s" % name)
        phandles.append(m.group(1))
    cpu_map = (
        "\t\tcpu-map {\n\n"
        "\t\t\tcluster0 {\n\n"
        "\t\t\t\tcore0 {\n\t\t\t\t\tcpu = <%s>;\n\t\t\t\t};\n\n"
        "\t\t\t\tcore1 {\n\t\t\t\t\tcpu = <%s>;\n\t\t\t\t};\n"
        "\t\t\t};\n\t\t};\n\n" % tuple(phandles)
    )
    cpus = re.compile(r"(\tcpus \{\n\t\t#address-cells = <0x02>;\n\t\t#size-cells = <0x00>;\n\n)")
    dts, n = cpus.subn(lambda m: m.group(1) + cpu_map, dts, count=1)
    if n != 1:
        sys.exit("cpus node not found")

    # cpupm node -> rev2 exynos-cpupm node (see 3. above); the node must
    # hold exactly cpd_cl0 and sicd, so that nothing else is dropped
    if re.search(r"^\texynos-cpupm \{", dts, re.M):
        sys.exit("exynos-cpupm node already present")
    node = re.compile(r"^\tcpupm \{\n(?:\t\t.*\n|\n)*?\t\};\n", re.M)
    m = node.search(dts)
    if not m:
        sys.exit("cpupm node not found")
    children = re.findall(r"^\t\t(\S+) \{$", m.group(0), re.M)
    if sorted(children) != ["cpd_cl0", "sicd"]:
        sys.exit("cpupm node has unexpected children: %s" % ", ".join(children))
    dts = dts[:m.start()] + EXYNOS_CPUPM + dts[m.end():]

    open(dst, "w").write(dts)


if __name__ == "__main__":
    main()
