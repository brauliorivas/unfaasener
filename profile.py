"""One node with selectable hardware, operating system and public IP access.

Instructions:
Choose the node settings under Configure Profile, then instantiate the experiment.
Once ready, use the SSH command shown for your node. Bare-metal nodes already
have a public control IP; the routable-IP option explicitly requests one for VMs.
"""

import geni.portal as portal
import geni.rspec.pg
import geni.rspec.igext

pc = portal.context
request = pc.makeRequestRSpec()

pc.defineParameter("nodeName", "Name", portal.ParameterType.STRING, "node1")
pc.defineParameter(
    "nodeType", "Node Type", portal.ParameterType.STRING, "vm",
    [("raw", "Bare metal"), ("vm", "Xen VM")],
)
pc.defineParameter(
    "hardwareType", "Hardware Type", portal.ParameterType.NODETYPE, "",
    longDescription="Leave empty for any compatible hardware. For a VM, this selects its physical host type.",
)
pc.defineParameter(
    "diskImage", "Disk Image", portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU24-64-STD",
    longDescription="Choose an image compatible with your selected hardware architecture.",
)
pc.defineParameter(
    "routableIP", "Require Routable IP", portal.ParameterType.BOOLEAN, False,
    longDescription="Request a public control IP for a VM. Bare-metal nodes already have one.",
)
pc.defineParameter(
    "vmCores", "VM CPU cores", portal.ParameterType.INTEGER, 4,
    longDescription="Used only when Node Type is Xen VM.",
)
pc.defineParameter(
    "vmRAM", "VM RAM (MB)", portal.ParameterType.INTEGER, 8192,
    longDescription="Used only when Node Type is Xen VM.",
)
params = pc.bindParameters()

if params.nodeType == "vm":
    node = request.XenVM(params.nodeName)
    node.cores = params.vmCores
    node.ram = params.vmRAM
    if params.hardwareType:
        node.xen_ptype = params.hardwareType
else:
    node = request.RawPC(params.nodeName)
    if params.hardwareType:
        node.hardware_type = params.hardwareType

node.disk_image = params.diskImage
node.routable_control_ip = params.routableIP
pc.printRequestRSpec()
