/*
 * pve-cloudprovision web UI
 *
 *  Header, node menu -> Create Cloud Server   wizard, next to Create VM / Create CT
 *  VM -> Cloud Server                         state, network devices, reinstall
 *  Datacenter -> Cloud Servers                templates and cloud servers of the cluster
 *
 * Loaded after pvemanagerlib.js through a script tag pve-cloudprovision adds to
 * /usr/share/pve-manager/index.html.tpl.
 */
Ext.ns('PVE.cloudprovision');

PVE.cloudprovision.Utils = {
    // cluster wide lists are served by every node, ask the one we talk to
    apiNode: () => Proxmox.NodeName,

    splitList: (value) =>
        (Ext.isArray(value) ? value : String(value || '').split(/[\s,;]+/)).filter((v) => v !== ''),

    isValidCidr: function (text) {
        if (PVE.routedip && PVE.routedip.Utils && PVE.routedip.Utils.isValidCidr) {
            return PVE.routedip.Utils.isValidCidr(text);
        }
        return /^[0-9A-Fa-f:.]+(\/\d{1,3})?$/.test(text);
    },

    validateCidrs: function (value) {
        for (const cidr of PVE.cloudprovision.Utils.splitList(value)) {
            if (!PVE.cloudprovision.Utils.isValidCidr(cidr)) {
                return Ext.String.format(gettext('Invalid CIDR: {0}'), cidr);
            }
        }
        return true;
    },

    parseIPv4: function (ip) {
        let parts = ip.split('.');
        if (parts.length !== 4) {
            return null;
        }
        let res = 0n;
        for (const part of parts) {
            if (!/^\d{1,3}$/.test(part) || Number(part) > 255) {
                return null;
            }
            res = (res << 8n) | BigInt(part);
        }
        return res;
    },

    parseIPv6: function (ip) {
        let halves = ip.toLowerCase().split('::');
        if (halves.length > 2) {
            return null;
        }
        let head = halves[0] ? halves[0].split(':') : [];
        let tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
        let missing = 8 - head.length - tail.length;
        if ((halves.length === 1 && missing !== 0) || missing < 0) {
            return null;
        }
        let groups = [...head, ...Array(halves.length === 2 ? missing : 0).fill('0'), ...tail];
        let res = 0n;
        for (const group of groups) {
            if (!/^[0-9a-f]{1,4}$/.test(group)) {
                return null;
            }
            res = (res << 16n) | BigInt('0x' + group);
        }
        return res;
    },

    formatIPv4: (value) =>
        [24n, 16n, 8n, 0n].map((shift) => String((value >> shift) & 255n)).join('.'),

    // RFC 5952: lowercase, longest run of two or more zero groups compressed
    formatIPv6: function (value) {
        let groups = [];
        for (let shift = 112n; shift >= 0n; shift -= 16n) {
            groups.push(((value >> shift) & 0xffffn).toString(16));
        }
        let best = { start: -1, len: 0 };
        for (let i = 0; i < 8; ) {
            if (groups[i] !== '0') {
                i++;
                continue;
            }
            let j = i;
            while (j < 8 && groups[j] === '0') {
                j++;
            }
            if (j - i > best.len && j - i > 1) {
                best = { start: i, len: j - i };
            }
            i = j;
        }
        if (best.start < 0) {
            return groups.join(':');
        }
        let head = groups.slice(0, best.start).join(':');
        let tail = groups.slice(best.start + best.len).join(':');
        return `${head}::${tail}`;
    },

    // the guest address of a routed CIDR, like the server side: a host route as
    // is, of a network the first address after the network address
    guestAddress: function (cidr) {
        let U = PVE.cloudprovision.Utils;
        let match = /^([0-9A-Fa-f:.]+)(?:\/(\d{1,3}))?$/.exec(cidr);
        if (!match) {
            return null;
        }
        let v6 = match[1].includes(':');
        let bits = v6 ? 128 : 32;
        let value = v6 ? U.parseIPv6(match[1]) : U.parseIPv4(match[1]);
        let len = match[2] === undefined ? bits : Number(match[2]);
        if (value === null || len > bits) {
            return null;
        }
        if (len < bits) {
            let host = (1n << BigInt(bits - len)) - 1n;
            value = (value & ~host) + 1n;
        }
        return v6 ? U.formatIPv6(value) : U.formatIPv4(value);
    },

    // guest addresses (cloud-init) of a NIC as the server will set them
    guestIps: function (nic) {
        let U = PVE.cloudprovision.Utils;
        let cidrs = U.splitList(nic.cidr);
        let first4 = cidrs.find((c) => !c.includes(':'));
        let first6 = cidrs.find((c) => c.includes(':'));
        let res = [];
        if (nic.ip) {
            res.push(nic.ip);
        } else if (first4) {
            res.push(U.guestAddress(first4) + '/32');
        }
        if (nic.ip6) {
            res.push(nic.ip6);
        } else if (first6) {
            res.push(U.guestAddress(first6) + '/128');
        }
        return res;
    },

    nicKeys: [
        'bridge', 'model', 'macaddr', 'tag', 'firewall', 'rate', 'mtu', 'queues',
        'cidr', 'tap-only', 'rp-filter', 'gateway4', 'gateway6',
        'ip', 'gw', 'ip6', 'gw6',
        'traffic', 'quota', 'quota-rate', 'direction',
    ],

    booleanNicKeys: ['firewall', 'tap-only', 'rp-filter', 'traffic'],

    // the netX property string of the create API
    printNic: function (nic) {
        let U = PVE.cloudprovision.Utils;
        let parts = [];
        for (const key of U.nicKeys) {
            let value = nic[key];
            if (key === 'cidr') {
                value = U.splitList(value).join(';');
            }
            if (U.booleanNicKeys.includes(key)) {
                if (value === undefined || value === null || value === '') {
                    continue;
                }
                value = value ? 1 : 0;
            }
            if (value === undefined || value === null || value === '') {
                continue;
            }
            parts.push(`${key}=${value}`);
        }
        return parts.join(',');
    },

    renderState: function (value, metaData, record) {
        let text = {
            creating: gettext('Creating'),
            reinstalling: gettext('Reinstalling'),
            ready: gettext('Ready'),
            error: gettext('Error'),
        }[value];
        if (!value) {
            return '';
        }
        let cls = { ready: 'fa-check good', error: 'fa-times critical' }[value] || 'fa-spinner fa-pulse';
        let res = `<i class="fa ${cls}"></i> ${Ext.htmlEncode(text || value)}`;
        let error = record && record.data ? record.data.error : undefined;
        if (value === 'error' && error) {
            metaData.tdAttr = 'data-qtip="' + Ext.htmlEncode(Ext.htmlEncode(error)) + '"';
        }
        return res;
    },

    renderTemplate: function (value, metaData, record) {
        if (!value) {
            return '';
        }
        let name = record.data['template-name'];
        return Ext.htmlEncode(name ? `${value} (${name})` : value);
    },

    renderList: (value) =>
        PVE.cloudprovision.Utils.splitList(value).map(Ext.htmlEncode).join('<br>'),

    canCreate: function () {
        let caps = Ext.state.Manager.get('GuiCap');
        return !!caps && !!caps.vms['VM.Allocate'];
    },

    openCreateWizard: function (nodename) {
        Ext.create('PVE.cloudprovision.CreateWizard', {
            nodename: nodename,
            autoShow: true,
        });
    },

    selectGuest: function (vmid) {
        let workspace = Ext.ComponentQuery.query('pveStdWorkspace')[0];
        if (workspace) {
            workspace.selectById(`qemu/${vmid}`);
        }
    },
};

Proxmox.Utils.override_task_descriptions({
    cpcreate: ['VM', gettext('Create cloud server')],
    cpreinstall: ['VM', gettext('Reinstall')],
});

Ext.define('pve-cloudprovision-template', {
    extend: 'Ext.data.Model',
    fields: [
        { name: 'vmid', type: 'integer' },
        'name',
        'node',
        'ostype',
        'description',
        'tags',
        'cpu',
        'bios',
        'storage',
        'boot-disk',
        { name: 'disk-size', type: 'integer' },
        { name: 'cores', type: 'integer' },
        { name: 'sockets', type: 'integer' },
        { name: 'memory', type: 'integer' },
        { name: 'cloudinit', type: 'boolean' },
        { name: 'shared', type: 'boolean' },
        { name: 'direct', type: 'boolean' },
        {
            name: 'text',
            calculate: (data) => `${data.vmid} (${data.name})`,
        },
    ],
    idProperty: 'vmid',
});

Ext.define('pve-cloudprovision-server', {
    extend: 'Ext.data.Model',
    fields: [
        { name: 'vmid', type: 'integer' },
        'name',
        'node',
        'state',
        'error',
        'task',
        { name: 'template', type: 'integer' },
        'template-name',
        { name: 'created', type: 'date', dateFormat: 'timestamp' },
        { name: 'reinstalled', type: 'date', dateFormat: 'timestamp' },
        { name: 'orphan', type: 'boolean' },
    ],
    idProperty: 'vmid',
});

Ext.define('pve-cloudprovision-nic', {
    extend: 'Ext.data.Model',
    fields: PVE.cloudprovision.Utils.nicKeys.concat(['net']),
});

Ext.define('PVE.cloudprovision.TemplateSelector', {
    extend: 'Proxmox.form.ComboGrid',
    alias: 'widget.pveCloudProvisionTemplateSelector',

    valueField: 'vmid',
    displayField: 'text',
    allowBlank: false,
    editable: false,

    store: {
        model: 'pve-cloudprovision-template',
        sorters: 'vmid',
    },

    listConfig: {
        width: 620,
        columns: [
            { header: 'VMID', dataIndex: 'vmid', width: 70 },
            { header: gettext('Name'), dataIndex: 'name', flex: 1, renderer: Ext.htmlEncode },
            { header: gettext('Node'), dataIndex: 'node', width: 90, renderer: Ext.htmlEncode },
            {
                header: gettext('Disk'),
                dataIndex: 'disk-size',
                width: 80,
                renderer: (v) => Proxmox.Utils.format_size(v),
            },
            {
                header: 'Cloud-Init',
                dataIndex: 'cloudinit',
                width: 75,
                renderer: Proxmox.Utils.format_boolean,
            },
            {
                header: gettext('Clone'),
                dataIndex: 'direct',
                width: 90,
                renderer: (direct) => (direct ? gettext('direct') : gettext('+ migrate')),
            },
        ],
    },

    setNodename: function (nodename) {
        let me = this;
        if (!nodename || me.nodename === nodename) {
            return;
        }
        me.nodename = nodename;
        me.store.setProxy({
            type: 'proxmox',
            url: `/api2/json/nodes/${nodename}/cloudprovision/templates`,
        });
        me.store.load();
    },

    initComponent: function () {
        let me = this;
        let nodename = me.nodename;
        me.nodename = undefined;
        me.callParent();
        me.setNodename(nodename || PVE.cloudprovision.Utils.apiNode());
    },
});

// Edit one NIC of a create request (no API call, values go to the callback).
Ext.define('PVE.cloudprovision.NicEdit', {
    extend: 'Ext.window.Window',

    width: 860,
    modal: true,
    resizable: false,
    border: false,
    layout: 'fit',

    nodename: undefined,
    values: undefined,
    callback: undefined,

    initComponent: function () {
        let me = this;

        let directionItems = [
            ['__default__', Proxmox.Utils.defaultText],
            ['both', gettext('In + out')],
            ['in', gettext('In (received)')],
            ['out', gettext('Out (sent)')],
            ['max', gettext('Larger of in and out')],
        ];

        me.form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            layout: 'column',
            defaults: {
                columnWidth: 0.5,
                border: false,
                padding: '0 5',
                defaults: { anchor: '100%', labelWidth: 120 },
            },
            items: [
                {
                    items: [
                        {
                            xtype: 'fieldset',
                            title: gettext('Network Device'),
                            defaults: { anchor: '100%', labelWidth: 110 },
                            items: [
                                {
                                    xtype: 'PVE.form.BridgeSelector',
                                    name: 'bridge',
                                    fieldLabel: gettext('Bridge'),
                                    nodename: me.nodename,
                                    autoSelect: true,
                                    allowBlank: false,
                                },
                                {
                                    xtype: 'pveVlanField',
                                    name: 'tag',
                                    value: '',
                                },
                                {
                                    xtype: 'pveNetworkCardSelector',
                                    name: 'model',
                                    fieldLabel: gettext('Model'),
                                    value: 'virtio',
                                    allowBlank: false,
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'macaddr',
                                    fieldLabel: gettext('MAC address'),
                                    vtype: 'MacAddress',
                                    emptyText: 'auto',
                                    allowBlank: true,
                                },
                                {
                                    xtype: 'proxmoxcheckbox',
                                    name: 'firewall',
                                    fieldLabel: gettext('Firewall'),
                                    checked: true,
                                },
                                {
                                    xtype: 'numberfield',
                                    name: 'rate',
                                    fieldLabel: gettext('Rate limit') + ' (MB/s)',
                                    minValue: 0,
                                    maxValue: 10 * 1024,
                                    decimalPrecision: 3,
                                    step: 1,
                                    emptyText: gettext('unlimited'),
                                },
                            ],
                        },
                        {
                            xtype: 'fieldset',
                            title: gettext('Routed IPs') + ' (pve-routedip)',
                            defaults: { anchor: '100%', labelWidth: 110 },
                            items: [
                                {
                                    xtype: 'textareafield',
                                    name: 'cidr',
                                    fieldLabel: gettext('Routed IPs'),
                                    height: 90,
                                    emptyText: '203.0.113.10\n198.51.100.0/29\n2001:db8:10::/64',
                                    validator: PVE.cloudprovision.Utils.validateCidrs,
                                    listeners: {
                                        change: () => me.updatePreview(),
                                    },
                                },
                                {
                                    xtype: 'proxmoxcheckbox',
                                    name: 'tap-only',
                                    fieldLabel: gettext('Tap only'),
                                    boxLabel: gettext('Point-to-point, not in the bridge'),
                                    listeners: {
                                        change: (field, value) =>
                                            me.down('field[name=rp-filter]').setDisabled(!value),
                                    },
                                },
                                {
                                    xtype: 'proxmoxcheckbox',
                                    name: 'rp-filter',
                                    fieldLabel: 'rp_filter',
                                    boxLabel: gettext('Only routed source addresses (IPv4)'),
                                    disabled: true,
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'gateway4',
                                    fieldLabel: gettext('IPv4 Gateway'),
                                    emptyText: gettext('Cluster default'),
                                    vtype: 'IPAddress',
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'gateway6',
                                    fieldLabel: gettext('IPv6 Gateway'),
                                    emptyText: gettext('Cluster default'),
                                    vtype: 'IP6Address',
                                },
                            ],
                        },
                    ],
                },
                {
                    items: [
                        {
                            xtype: 'fieldset',
                            title: gettext('Guest IP') + ' (Cloud-Init)',
                            defaults: { anchor: '100%', labelWidth: 110 },
                            items: [
                                {
                                    xtype: 'displayfield',
                                    itemId: 'preview',
                                    fieldLabel: gettext('Guest addresses'),
                                    value: '-',
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'ip',
                                    fieldLabel: 'IPv4/CIDR',
                                    emptyText: gettext('from the routed IPs'),
                                    validator: (v) =>
                                        !v || v === 'dhcp' || v === 'manual' || Ext.form.VTypes.IPCIDRAddress(v)
                                            ? true
                                            : gettext("Use 'dhcp', 'manual' or an address in CIDR notation"),
                                    listeners: { change: () => me.updatePreview() },
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'gw',
                                    fieldLabel: gettext('Gateway') + ' (IPv4)',
                                    emptyText: gettext('routed IP gateway'),
                                    vtype: 'IPAddress',
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'ip6',
                                    fieldLabel: 'IPv6/CIDR',
                                    emptyText: gettext('from the routed IPs'),
                                    validator: (v) =>
                                        !v || ['auto', 'dhcp', 'manual'].includes(v) || Ext.form.VTypes.IP6CIDRAddress(v)
                                            ? true
                                            : gettext("Use 'auto', 'dhcp', 'manual' or an address in CIDR notation"),
                                    listeners: { change: () => me.updatePreview() },
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'gw6',
                                    fieldLabel: gettext('Gateway') + ' (IPv6)',
                                    emptyText: gettext('routed IP gateway'),
                                    vtype: 'IP6Address',
                                },
                                {
                                    xtype: 'displayfield',
                                    userCls: 'pmx-hint',
                                    value: gettext(
                                        'Empty: the first routed IPv4/IPv6 CIDR is used, a host route (/32, /128) as is, of a network its first address.',
                                    ),
                                },
                            ],
                        },
                        {
                            xtype: 'fieldset',
                            title: gettext('Traffic') + ' (pve-trafficd)',
                            defaults: { anchor: '100%', labelWidth: 110 },
                            items: [
                                {
                                    xtype: 'proxmoxcheckbox',
                                    name: 'traffic',
                                    fieldLabel: gettext('Count traffic'),
                                    boxLabel: gettext('Also without quota'),
                                },
                                {
                                    xtype: 'textfield',
                                    name: 'quota',
                                    fieldLabel: gettext('Quota'),
                                    emptyText: gettext('none') + ' (e.g. 1T, 500GB)',
                                    regex: /^\d+(\.\d+)?\s*([KMGTP](i|iB|B)?)?$/i,
                                    regexText: gettext('Bytes or a size like 1T, 500GB'),
                                },
                                {
                                    xtype: 'numberfield',
                                    name: 'quota-rate',
                                    fieldLabel: gettext('Limit at quota') + ' (MB/s)',
                                    minValue: 0.001,
                                    decimalPrecision: 3,
                                    emptyText: Proxmox.Utils.defaultText,
                                },
                                {
                                    xtype: 'proxmoxKVComboBox',
                                    name: 'direction',
                                    fieldLabel: gettext('Counted'),
                                    comboItems: directionItems,
                                    value: '__default__',
                                },
                            ],
                        },
                    ],
                },
            ],
        });

        Ext.apply(me, {
            title: gettext('Network Device'),
            items: [me.form],
            buttons: [
                {
                    text: gettext('OK'),
                    handler: () => me.submit(),
                },
                {
                    text: gettext('Cancel'),
                    handler: () => me.close(),
                },
            ],
        });

        me.callParent();

        if (me.values) {
            let values = Ext.apply({}, me.values);
            values.cidr = PVE.cloudprovision.Utils.splitList(values.cidr).join('\n');
            values.direction = values.direction || '__default__';
            me.form.getForm().setValues(values);
        }
        me.updatePreview();
    },

    updatePreview: function () {
        let me = this;
        if (!me.form) {
            return;
        }
        let values = me.form.getForm().getFieldValues();
        let ips = PVE.cloudprovision.Utils.guestIps(values);
        me.down('#preview').setValue(ips.length ? ips.map(Ext.htmlEncode).join('<br>') : '-');
    },

    submit: function () {
        let me = this;
        let form = me.form.getForm();
        if (!form.isValid()) {
            return;
        }
        let values = form.getFieldValues();
        let res = {};
        for (const key of PVE.cloudprovision.Utils.nicKeys) {
            let value = values[key];
            if (key === 'cidr') {
                value = PVE.cloudprovision.Utils.splitList(value).join(';');
            }
            if (key === 'direction' && value === '__default__') {
                value = undefined;
            }
            if (key === 'rp-filter' && !values['tap-only']) {
                value = undefined;
            }
            if (PVE.cloudprovision.Utils.booleanNicKeys.includes(key)) {
                value = value ? 1 : 0;
                if (!value && key !== 'firewall') {
                    continue;
                }
            }
            if (value === undefined || value === null || value === '') {
                continue;
            }
            res[key] = value;
        }
        me.callback(res);
        me.close();
    },
});

// Network tab of the wizard: NICs as a list, net0... in list order
Ext.define('PVE.cloudprovision.NicPanel', {
    extend: 'Proxmox.panel.InputPanel',
    alias: 'widget.pveCloudProvisionNicPanel',

    layout: 'fit',
    nodename: undefined,

    setNodename: function (nodename) {
        this.nodename = nodename;
    },

    onGetValues: function () {
        let me = this;
        let values = {};
        me.store.each((rec, i) => {
            values[`net${i}`] = PVE.cloudprovision.Utils.printNic(rec.data);
        });
        return values;
    },

    initComponent: function () {
        let me = this;

        me.store = Ext.create('Ext.data.Store', {
            model: 'pve-cloudprovision-nic',
            data: [{ bridge: 'vmbr0', model: 'virtio', firewall: 1 }],
        });

        let sm = Ext.create('Ext.selection.RowModel', {});

        let edit = function (rec) {
            Ext.create('PVE.cloudprovision.NicEdit', {
                nodename: me.nodename,
                values: rec ? rec.data : undefined,
                autoShow: true,
                callback: (values) => {
                    if (rec) {
                        let data = {};
                        for (const key of PVE.cloudprovision.Utils.nicKeys) {
                            data[key] = values[key];
                        }
                        rec.set(data);
                    } else {
                        me.store.add(values);
                    }
                },
            });
        };

        let netName = (value, meta, rec) => `net${me.store.indexOf(rec)}`;

        me.items = [
            {
                xtype: 'grid',
                store: me.store,
                selModel: sm,
                tbar: [
                    {
                        text: gettext('Add'),
                        handler: () => edit(),
                    },
                    {
                        xtype: 'proxmoxButton',
                        text: gettext('Edit'),
                        selModel: sm,
                        disabled: true,
                        handler: () => edit(sm.getSelection()[0]),
                    },
                    {
                        xtype: 'proxmoxButton',
                        text: gettext('Remove'),
                        selModel: sm,
                        disabled: true,
                        handler: () => me.store.remove(sm.getSelection()),
                    },
                    '->',
                    {
                        xtype: 'displayfield',
                        userCls: 'pmx-hint',
                        value: gettext("No device: the template's network devices are kept."),
                    },
                ],
                listeners: {
                    itemdblclick: (view, rec) => edit(rec),
                },
                columns: [
                    { header: gettext('Device'), width: 60, sortable: false, renderer: netName },
                    {
                        header: gettext('Bridge'),
                        dataIndex: 'bridge',
                        width: 100,
                        renderer: (v, m, rec) =>
                            Ext.htmlEncode(v) + (rec.data.tag ? ` (VLAN ${Ext.htmlEncode(rec.data.tag)})` : ''),
                    },
                    {
                        header: gettext('Rate limit'),
                        dataIndex: 'rate',
                        width: 80,
                        renderer: (v) => (v ? `${v} MB/s` : gettext('none')),
                    },
                    {
                        header: gettext('Routed IPs'),
                        dataIndex: 'cidr',
                        flex: 1,
                        renderer: PVE.cloudprovision.Utils.renderList,
                    },
                    {
                        header: gettext('Guest IP'),
                        dataIndex: 'ip',
                        flex: 1,
                        renderer: (v, m, rec) =>
                            PVE.cloudprovision.Utils.guestIps(rec.data).map(Ext.htmlEncode).join('<br>'),
                    },
                    {
                        header: gettext('Quota'),
                        dataIndex: 'quota',
                        width: 90,
                        renderer: (v, m, rec) =>
                            v ? Ext.htmlEncode(v) : rec.data.traffic ? gettext('counted') : '',
                    },
                ],
            },
        ];

        me.callParent();
    },
});

// Hardware tab: data disks
Ext.define('PVE.cloudprovision.DataDiskEdit', {
    extend: 'Ext.window.Window',

    width: 400,
    modal: true,
    resizable: false,
    title: gettext('Data Disk'),

    nodename: undefined,
    callback: undefined,

    initComponent: function () {
        let me = this;

        me.form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            defaults: { anchor: '100%' },
            items: [
                {
                    xtype: 'proxmoxintegerfield',
                    name: 'size',
                    fieldLabel: gettext('Disk size') + ' (GiB)',
                    minValue: 1,
                    value: 10,
                    allowBlank: false,
                },
                {
                    xtype: 'pveStorageSelector',
                    name: 'storage',
                    fieldLabel: gettext('Storage'),
                    nodename: me.nodename,
                    storageContent: 'images',
                    allowBlank: true,
                    autoSelect: false,
                    emptyText: gettext('Storage of the system disk'),
                },
            ],
        });

        Ext.apply(me, {
            items: [me.form],
            buttons: [
                {
                    text: gettext('Add'),
                    handler: function () {
                        if (!me.form.getForm().isValid()) {
                            return;
                        }
                        let values = me.form.getForm().getFieldValues();
                        me.callback({ size: values.size, storage: values.storage || undefined });
                        me.close();
                    },
                },
            ],
        });
        me.callParent();
    },
});

Ext.define('PVE.cloudprovision.HardwarePanel', {
    extend: 'Proxmox.panel.InputPanel',
    alias: 'widget.pveCloudProvisionHardwarePanel',

    nodename: undefined,

    setNodename: function (nodename) {
        this.nodename = nodename;
    },

    // defaults from the selected template
    setTemplate: function (tpl) {
        let me = this;
        let set = (name, value, text) => {
            let field = me.down(`field[name=${name}]`);
            field.setEmptyText(text ?? `${value} (${gettext('template')})`);
        };
        if (!tpl) {
            return;
        }
        set('cores', tpl.cores);
        set('sockets', tpl.sockets);
        set('memory', tpl.memory);
        set('cpu', tpl.cpu || Proxmox.Utils.defaultText, `${tpl.cpu || Proxmox.Utils.defaultText} (${gettext('template')})`);
    },

    onGetValues: function (values) {
        let me = this;
        for (const key of ['cores', 'sockets', 'memory', 'balloon', 'cpu']) {
            if (values[key] === '' || values[key] === null || values[key] === undefined) {
                delete values[key];
            }
        }
        delete values.delete;
        me.diskStore.each((rec, i) => {
            let disk = `size=${rec.data.size}`;
            if (rec.data.storage) {
                disk += `,storage=${rec.data.storage}`;
            }
            values[`datadisk${i}`] = disk;
        });
        return values;
    },

    initComponent: function () {
        let me = this;

        me.diskStore = Ext.create('Ext.data.Store', { fields: ['size', 'storage'] });
        let sm = Ext.create('Ext.selection.RowModel', {});

        me.column1 = [
            {
                xtype: 'proxmoxintegerfield',
                name: 'cores',
                fieldLabel: gettext('Cores'),
                minValue: 1,
                maxValue: 1024,
            },
            {
                xtype: 'proxmoxintegerfield',
                name: 'sockets',
                fieldLabel: gettext('Sockets'),
                minValue: 1,
                maxValue: 4,
            },
            {
                xtype: 'CPUModelSelector',
                name: 'cpu',
                fieldLabel: gettext('CPU Type'),
                deleteEmpty: false,
            },
        ];
        me.column2 = [
            {
                xtype: 'proxmoxintegerfield',
                name: 'memory',
                fieldLabel: gettext('Memory') + ' (MiB)',
                minValue: 16,
                step: 256,
            },
        ];
        me.advancedColumn2 = [
            {
                xtype: 'proxmoxintegerfield',
                name: 'balloon',
                fieldLabel: gettext('Minimum memory') + ' (MiB)',
                minValue: 0,
                emptyText: Proxmox.Utils.defaultText,
            },
        ];
        me.columnB = [
            {
                xtype: 'grid',
                title: gettext('Data disks'),
                height: 200,
                store: me.diskStore,
                selModel: sm,
                tbar: [
                    {
                        text: gettext('Add'),
                        handler: () =>
                            Ext.create('PVE.cloudprovision.DataDiskEdit', {
                                nodename: me.nodename,
                                autoShow: true,
                                callback: (disk) => me.diskStore.add(disk),
                            }),
                    },
                    {
                        xtype: 'proxmoxButton',
                        text: gettext('Remove'),
                        selModel: sm,
                        disabled: true,
                        handler: () => me.diskStore.remove(sm.getSelection()),
                    },
                    '->',
                    {
                        xtype: 'displayfield',
                        userCls: 'pmx-hint',
                        value: gettext('Empty disks next to the system disk, kept by a reinstall.'),
                    },
                ],
                columns: [
                    { header: '#', width: 50, renderer: (v, m, rec) => me.diskStore.indexOf(rec) },
                    {
                        header: gettext('Size'),
                        dataIndex: 'size',
                        width: 100,
                        renderer: (v) => `${v} GiB`,
                    },
                    {
                        header: gettext('Storage'),
                        dataIndex: 'storage',
                        flex: 1,
                        renderer: (v) => (v ? Ext.htmlEncode(v) : gettext('Storage of the system disk')),
                    },
                ],
            },
        ];

        me.callParent();
    },
});

Ext.define('PVE.cloudprovision.CreateWizard', {
    extend: 'PVE.window.Wizard',
    alias: 'widget.pveCloudProvisionCreateWizard',
    mixins: ['Proxmox.Mixin.CBind'],

    subject: gettext('Cloud Server'),
    width: 860,
    height: 600,

    viewModel: {
        data: {
            nodename: '',
        },
    },

    cbindData: {
        nodename: undefined,
    },

    // fields that are only shown or used in the summary
    summaryHidden: ['cipassword'],

    templateRecord: function () {
        let field = this.down('field[name=template]');
        let value = field.getValue();
        return value ? field.getStore().getById(value) : null;
    },

    onTemplateChange: function () {
        let me = this;
        let tpl = me.templateRecord();
        let info = me.down('#templateinfo');
        let size = me.down('field[name=disksize]');
        if (!tpl) {
            info.setValue('');
            return;
        }
        let gib = Math.ceil((tpl.data['disk-size'] || 0) / 1024 ** 3);
        size.setMinValue(Math.max(gib, 1));
        size.setEmptyText(`${gib} GiB (${gettext('template')})`);
        size.validate();

        let rows = [
            [gettext('Node'), tpl.data.node],
            [gettext('OS type'), tpl.data.ostype || '-'],
            [gettext('CPU'), `${tpl.data.sockets} x ${tpl.data.cores}`],
            [gettext('Memory'), `${tpl.data.memory} MiB`],
            [gettext('Disk'), `${tpl.data['boot-disk'] || '-'}, ${Proxmox.Utils.format_size(tpl.data['disk-size'] || 0)} (${tpl.data.storage || '-'})`],
            ['Cloud-Init', tpl.data.cloudinit ? Proxmox.Utils.yesText : gettext('No (a drive is added)')],
            [
                gettext('Clone'),
                tpl.data.direct
                    ? gettext('directly on this node')
                    : Ext.String.format(gettext("on node '{0}', then migrated"), tpl.data.node),
            ],
        ];
        if (tpl.data.description) {
            rows.push([gettext('Notes'), tpl.data.description]);
        }
        info.setValue(
            '<table>' +
                rows
                    .map(([k, v]) => `<tr><td style="padding-right:10px"><b>${Ext.htmlEncode(k)}</b></td><td>${Ext.htmlEncode(v)}</td></tr>`)
                    .join('') +
                '</table>',
        );

        me.down('pveCloudProvisionHardwarePanel').setTemplate(tpl.data);
    },

    items: [
        {
            xtype: 'inputpanel',
            title: gettext('General'),
            column1: [
                {
                    xtype: 'pveNodeSelector',
                    name: 'nodename',
                    cbind: {
                        selectCurNode: '{!nodename}',
                        preferredValue: '{nodename}',
                    },
                    bind: {
                        value: '{nodename}',
                    },
                    fieldLabel: gettext('Node'),
                    allowBlank: false,
                    onlineValidator: true,
                },
                {
                    xtype: 'pveGuestIDSelector',
                    name: 'vmid',
                    guestType: 'qemu',
                    value: '',
                    loadNextFreeID: true,
                    validateExists: false,
                },
                {
                    xtype: 'textfield',
                    name: 'name',
                    vtype: 'DnsName',
                    value: '',
                    fieldLabel: gettext('Name'),
                    emptyText: 'vm<VMID>',
                    allowBlank: true,
                },
            ],
            column2: [
                {
                    xtype: 'pvePoolSelector',
                    fieldLabel: gettext('Resource Pool'),
                    name: 'pool',
                    value: '',
                    allowBlank: true,
                },
                {
                    xtype: 'proxmoxcheckbox',
                    name: 'onboot',
                    uncheckedValue: 0,
                    fieldLabel: gettext('Start at boot'),
                },
            ],
            advancedColumnB: [
                {
                    xtype: 'pveTagFieldSet',
                    name: 'tags',
                    maxHeight: 150,
                },
                {
                    xtype: 'textarea',
                    name: 'description',
                    fieldLabel: gettext('Notes'),
                    height: 60,
                },
            ],
            onGetValues: function (values) {
                for (const key of ['name', 'pool', 'onboot', 'tags', 'description']) {
                    if (!values[key]) {
                        delete values[key];
                    }
                }
                return values;
            },
        },
        {
            xtype: 'inputpanel',
            title: gettext('Template'),
            column1: [
                {
                    xtype: 'pveCloudProvisionTemplateSelector',
                    name: 'template',
                    fieldLabel: gettext('Template'),
                    bind: {
                        nodename: '{nodename}',
                    },
                    listeners: {
                        change: function () {
                            this.up('window').onTemplateChange();
                        },
                    },
                },
                {
                    xtype: 'pveStorageSelector',
                    name: 'storage',
                    fieldLabel: gettext('Storage'),
                    storageContent: 'images',
                    allowBlank: true,
                    autoSelect: false,
                    emptyText: gettext("Template's storage"),
                    bind: {
                        nodename: '{nodename}',
                    },
                },
                {
                    xtype: 'proxmoxintegerfield',
                    name: 'disksize',
                    fieldLabel: gettext('Disk size') + ' (GiB)',
                    minValue: 1,
                    allowBlank: true,
                },
            ],
            column2: [
                {
                    xtype: 'displayfield',
                    itemId: 'templateinfo',
                    fieldLabel: gettext('Template'),
                    labelAlign: 'top',
                    value: '',
                },
            ],
            advancedColumn1: [
                {
                    xtype: 'proxmoxcheckbox',
                    name: 'full',
                    fieldLabel: gettext('Full clone'),
                    checked: true,
                    uncheckedValue: 0,
                    listeners: {
                        change: function (field, value) {
                            let panel = field.up('inputpanel');
                            panel.down('field[name=storage]').setDisabled(!value);
                            panel.down('field[name=disksize]').setDisabled(!value);
                        },
                    },
                },
            ],
            onGetValues: function (values) {
                if (!values.storage) {
                    delete values.storage;
                }
                if (!values.disksize) {
                    delete values.disksize;
                }
                if (values.full) {
                    delete values.full;
                } else {
                    values.full = 0;
                }
                return values;
            },
        },
        {
            xtype: 'pveCloudProvisionHardwarePanel',
            title: gettext('Hardware'),
            bind: {
                nodename: '{nodename}',
            },
        },
        {
            xtype: 'pveCloudProvisionNicPanel',
            title: gettext('Network'),
            bind: {
                nodename: '{nodename}',
            },
        },
        {
            xtype: 'inputpanel',
            title: 'Cloud-Init',
            column1: [
                {
                    xtype: 'textfield',
                    name: 'ciuser',
                    fieldLabel: gettext('User'),
                    emptyText: gettext('Default'),
                    allowBlank: true,
                },
                {
                    xtype: 'textfield',
                    inputType: 'password',
                    name: 'cipassword',
                    fieldLabel: gettext('Password'),
                    emptyText: gettext('none'),
                    allowBlank: true,
                },
                {
                    xtype: 'textfield',
                    inputType: 'password',
                    name: 'cipassword-confirm',
                    fieldLabel: gettext('Confirm password'),
                    submitValue: false,
                    allowBlank: true,
                    validator: function (value) {
                        let pw = this.up('inputpanel').down('field[name=cipassword]').getValue();
                        return value === pw ? true : gettext('Passwords do not match');
                    },
                },
            ],
            column2: [
                {
                    xtype: 'textfield',
                    name: 'nameserver',
                    fieldLabel: gettext('DNS servers'),
                    emptyText: gettext('use host settings'),
                    allowBlank: true,
                },
                {
                    xtype: 'textfield',
                    name: 'searchdomain',
                    fieldLabel: gettext('DNS domain'),
                    emptyText: gettext('use host settings'),
                    allowBlank: true,
                },
                {
                    xtype: 'proxmoxKVComboBox',
                    name: 'ciupgrade',
                    fieldLabel: gettext('Upgrade packages'),
                    value: '__default__',
                    comboItems: [
                        ['__default__', Proxmox.Utils.defaultText],
                        ['1', Proxmox.Utils.yesText],
                        ['0', Proxmox.Utils.noText],
                    ],
                },
            ],
            columnB: [
                {
                    xtype: 'textarea',
                    name: 'sshkeys',
                    fieldLabel: gettext('SSH public keys'),
                    labelAlign: 'top',
                    height: 150,
                    allowBlank: true,
                },
            ],
            onGetValues: function (values) {
                for (const key of ['ciuser', 'cipassword', 'nameserver', 'searchdomain']) {
                    if (!values[key]) {
                        delete values[key];
                    }
                }
                if (values.ciupgrade === '__default__' || values.ciupgrade === undefined) {
                    delete values.ciupgrade;
                }
                let keys = (values.sshkeys || '').trim();
                if (keys) {
                    values.sshkeys = encodeURIComponent(keys + '\n');
                } else {
                    delete values.sshkeys;
                }
                delete values.delete;
                return values;
            },
        },
        {
            title: gettext('Confirm'),
            layout: 'fit',
            items: [
                {
                    xtype: 'grid',
                    store: {
                        model: 'KeyValue',
                        sorters: [{ property: 'key', direction: 'ASC' }],
                    },
                    columns: [
                        { header: gettext('Key'), width: 150, dataIndex: 'key' },
                        {
                            header: gettext('Value'),
                            flex: 1,
                            dataIndex: 'value',
                            renderer: Ext.htmlEncode,
                        },
                    ],
                },
            ],
            dockedItems: [
                {
                    xtype: 'proxmoxcheckbox',
                    name: 'start',
                    dock: 'bottom',
                    margin: '5 0 0 0',
                    checked: true,
                    uncheckedValue: 0,
                    boxLabel: gettext('Start after created'),
                },
            ],
            listeners: {
                show: function (panel) {
                    let wizard = this.up('window');
                    let kv = wizard.getValues();
                    let data = [];
                    Ext.Object.each(kv, function (key, value) {
                        if (key === 'delete') {
                            return;
                        }
                        if (key === 'cipassword') {
                            value = '********';
                        } else if (key === 'sshkeys') {
                            value = decodeURIComponent(value);
                        }
                        data.push({ key: key, value: value });
                    });
                    let store = panel.down('grid').getStore();
                    store.suspendEvents();
                    store.removeAll();
                    store.add(data);
                    store.sort();
                    store.resumeEvents();
                    store.fireEvent('refresh');
                },
            },
            onSubmit: function () {
                let wizard = this.up('window');
                let kv = wizard.getValues();
                delete kv.delete;

                let nodename = kv.nodename;
                delete kv.nodename;

                Proxmox.Utils.API2Request({
                    url: `/nodes/${nodename}/cloudprovision`,
                    waitMsgTarget: wizard,
                    method: 'POST',
                    params: kv,
                    success: function (response) {
                        wizard.close();
                        Ext.create('Proxmox.window.TaskViewer', {
                            upid: response.result.data,
                            autoShow: true,
                        });
                    },
                    failure: function (response) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                });
            },
        },
    ],
});

Ext.define('PVE.cloudprovision.ReinstallWindow', {
    extend: 'Proxmox.window.Edit',
    alias: 'widget.pveCloudProvisionReinstall',

    width: 620,
    method: 'POST',
    isCreate: true,
    showTaskViewer: true,

    nodename: undefined,
    vmid: undefined,
    template: undefined,

    initComponent: function () {
        let me = this;

        me.url = `/nodes/${me.nodename}/qemu/${me.vmid}/cloudprovision/reinstall`;
        me.title = `${gettext('Reinstall')}: VM ${me.vmid}`;
        me.submitText = gettext('Reinstall');

        let ipanel = Ext.create('Proxmox.panel.InputPanel', {
            onGetValues: function (values) {
                for (const key of ['storage', 'ciuser', 'cipassword']) {
                    if (!values[key]) {
                        delete values[key];
                    }
                }
                let keys = (values.sshkeys || '').trim();
                if (keys) {
                    values.sshkeys = encodeURIComponent(keys + '\n');
                } else {
                    delete values.sshkeys;
                }
                if (values.start === '__default__') {
                    delete values.start;
                }
                delete values.confirm;
                delete values.delete;
                return values;
            },
            column1: [
                {
                    xtype: 'pveCloudProvisionTemplateSelector',
                    name: 'template',
                    fieldLabel: gettext('Template'),
                    nodename: me.nodename,
                    value: me.template,
                },
                {
                    xtype: 'pveStorageSelector',
                    name: 'storage',
                    fieldLabel: gettext('Storage'),
                    nodename: me.nodename,
                    storageContent: 'images',
                    allowBlank: true,
                    autoSelect: false,
                    emptyText: gettext('Current system disk'),
                },
                {
                    xtype: 'proxmoxKVComboBox',
                    name: 'start',
                    fieldLabel: gettext('Start'),
                    value: '__default__',
                    comboItems: [
                        ['__default__', gettext('If it was running')],
                        ['1', Proxmox.Utils.yesText],
                        ['0', Proxmox.Utils.noText],
                    ],
                },
            ],
            column2: [
                {
                    xtype: 'textfield',
                    name: 'ciuser',
                    fieldLabel: gettext('User'),
                    emptyText: gettext('unchanged'),
                },
                {
                    xtype: 'textfield',
                    inputType: 'password',
                    name: 'cipassword',
                    fieldLabel: gettext('New password'),
                    emptyText: gettext('unchanged'),
                },
            ],
            columnB: [
                {
                    xtype: 'textarea',
                    name: 'sshkeys',
                    fieldLabel: gettext('SSH public keys'),
                    labelAlign: 'top',
                    emptyText: gettext('unchanged'),
                    height: 90,
                },
                {
                    xtype: 'displayfield',
                    userCls: 'pmx-hint',
                    value: gettext(
                        'The system disks are replaced by the ones of the template, all data on them is lost. Data disks, network devices, CPU, memory, cloud-init settings, routed IPs and traffic counters are kept.',
                    ),
                },
                {
                    xtype: 'textfield',
                    name: 'confirm',
                    fieldLabel: Ext.String.format(gettext("Type '{0}' to confirm"), me.vmid),
                    labelWidth: 160,
                    allowBlank: false,
                    submitValue: false,
                    validator: (value) =>
                        String(value) === String(me.vmid) ? true : gettext('Enter the VM ID'),
                },
            ],
        });

        Ext.apply(me, { items: [ipanel] });
        me.callParent();
    },
});

// VM -> Cloud Server
Ext.define('PVE.cloudprovision.GuestPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveCloudProvisionGuestPanel',

    layout: {
        type: 'vbox',
        align: 'stretch',
    },

    reload: function () {
        let me = this;
        Proxmox.Utils.API2Request({
            url: me.baseUrl,
            method: 'GET',
            waitMsgTarget: me,
            success: function (response) {
                let data = response.result.data;
                me.info = data;
                let rows = [
                    [gettext('Cloud server'), data.managed ? Proxmox.Utils.yesText : gettext('No (not created by pve-cloudprovision)')],
                    [gettext('State'), data.state ? PVE.cloudprovision.Utils.renderState(data.state, {}, { data }) : '-'],
                    [
                        gettext('Template'),
                        data.template ? Ext.htmlEncode(`${data.template} (${data['template-name'] || '-'})`) : '-',
                    ],
                    [gettext('Created'), data.created ? Proxmox.Utils.render_timestamp(data.created) : '-'],
                    [gettext('Reinstalled'), data.reinstalled ? Proxmox.Utils.render_timestamp(data.reinstalled) : '-'],
                    [gettext('System disks'), Ext.htmlEncode((data['system-disks'] || []).join(', ')) || '-'],
                ];
                if (data.error) {
                    rows.push([gettext('Error'), Ext.htmlEncode(data.error)]);
                }
                me.infoStore.loadData(rows.map(([key, value]) => ({ key, value })));
                me.nicStore.loadData(data.nics || []);
                me.down('#reinstall').setDisabled(
                    !me.canReinstall || ['creating', 'reinstalling'].includes(data.state),
                );
            },
            failure: (response) => Proxmox.Utils.setErrorMask(me, response.htmlStatus),
        });
    },

    initComponent: function () {
        let me = this;

        let nodename = me.pveSelNode.data.node;
        let vmid = me.pveSelNode.data.vmid;
        me.baseUrl = `/nodes/${nodename}/qemu/${vmid}/cloudprovision`;

        let caps = Ext.state.Manager.get('GuiCap');
        me.canReinstall = !!caps.vms['VM.Allocate'] && !!caps.vms['VM.Config.Disk'] && !!caps.vms['VM.PowerMgmt'];

        me.infoStore = Ext.create('Ext.data.Store', { fields: ['key', 'value'] });
        me.nicStore = Ext.create('Ext.data.Store', {
            fields: ['net', 'model', 'macaddr', 'bridge', 'tag', 'rate', 'cidr', 'tap-only', 'ipconfig', 'ipconfig-auto', 'traffic', 'quota'],
        });

        Ext.apply(me, {
            tbar: [
                {
                    text: gettext('Reinstall'),
                    itemId: 'reinstall',
                    iconCls: 'fa fa-refresh',
                    disabled: true,
                    handler: function () {
                        Ext.create('PVE.cloudprovision.ReinstallWindow', {
                            nodename: nodename,
                            vmid: vmid,
                            template: me.info ? me.info.template : undefined,
                            autoShow: true,
                            listeners: {
                                destroy: () => me.reload(),
                            },
                        });
                    },
                },
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-repeat',
                    handler: () => me.reload(),
                },
            ],
            items: [
                {
                    xtype: 'grid',
                    store: me.infoStore,
                    hideHeaders: true,
                    border: false,
                    disableSelection: true,
                    columns: [
                        { dataIndex: 'key', width: 160, renderer: (v) => `<b>${Ext.htmlEncode(v)}</b>` },
                        // values are HTML (encoded where needed)
                        { dataIndex: 'value', flex: 1, renderer: (v) => v },
                    ],
                },
                {
                    xtype: 'grid',
                    title: gettext('Network Devices'),
                    store: me.nicStore,
                    flex: 1,
                    border: false,
                    columns: [
                        { header: gettext('Device'), dataIndex: 'net', width: 70 },
                        {
                            header: gettext('Bridge'),
                            dataIndex: 'bridge',
                            width: 120,
                            renderer: (v, m, rec) =>
                                Ext.htmlEncode(v || '') + (rec.data.tag ? ` (VLAN ${rec.data.tag})` : ''),
                        },
                        { header: gettext('MAC address'), dataIndex: 'macaddr', width: 140 },
                        {
                            header: gettext('Rate limit'),
                            dataIndex: 'rate',
                            width: 90,
                            renderer: (v) => (v ? `${v} MB/s` : gettext('none')),
                        },
                        {
                            header: gettext('Routed IPs'),
                            dataIndex: 'cidr',
                            flex: 1,
                            renderer: (v, m, rec) =>
                                PVE.cloudprovision.Utils.renderList(v) +
                                (rec.data['tap-only'] ? ` <i>(${gettext('tap only')})</i>` : ''),
                        },
                        {
                            header: gettext('Guest IP') + ' (Cloud-Init)',
                            dataIndex: 'ipconfig',
                            flex: 1,
                            renderer: (v, m, rec) =>
                                PVE.cloudprovision.Utils.renderList(v) +
                                (rec.data['ipconfig-auto'] ? ` <i>(${gettext('from routed IPs')})</i>` : ''),
                        },
                        {
                            header: gettext('Traffic quota'),
                            dataIndex: 'quota',
                            width: 110,
                            renderer: (v, m, rec) =>
                                v !== undefined && v !== null && v !== ''
                                    ? Proxmox.Utils.format_size(v)
                                    : rec.data.traffic
                                      ? gettext('counted')
                                      : '-',
                        },
                    ],
                },
            ],
            listeners: {
                activate: () => me.reload(),
            },
        });

        me.callParent();
        me.reload();
    },
});

// Datacenter -> Cloud Servers
Ext.define('PVE.cloudprovision.ClusterPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveCloudProvisionClusterPanel',

    layout: {
        type: 'vbox',
        align: 'stretch',
    },

    initComponent: function () {
        let me = this;
        let base = `/api2/json/nodes/${PVE.cloudprovision.Utils.apiNode()}/cloudprovision`;

        let servers = Ext.create('Proxmox.data.UpdateStore', {
            storeid: 'pve-cloudprovision-servers',
            interval: 5000,
            model: 'pve-cloudprovision-server',
            proxy: { type: 'proxmox', url: `${base}/servers` },
        });
        let templates = Ext.create('Proxmox.data.UpdateStore', {
            storeid: 'pve-cloudprovision-templates',
            interval: 20000,
            model: 'pve-cloudprovision-template',
            proxy: { type: 'proxmox', url: `${base}/templates` },
        });

        Ext.apply(me, {
            items: [
                {
                    xtype: 'grid',
                    title: gettext('Cloud servers'),
                    flex: 3,
                    border: false,
                    store: { type: 'diff', rstore: servers, sorters: 'vmid' },
                    tbar: [
                        {
                            text: gettext('Create Cloud Server'),
                            iconCls: 'fa fa-cloud',
                            disabled: !PVE.cloudprovision.Utils.canCreate(),
                            handler: () => PVE.cloudprovision.Utils.openCreateWizard(),
                        },
                    ],
                    listeners: {
                        itemdblclick: (view, rec) => {
                            if (!rec.data.orphan) {
                                PVE.cloudprovision.Utils.selectGuest(rec.data.vmid);
                            }
                        },
                    },
                    columns: [
                        { header: 'VMID', dataIndex: 'vmid', width: 80 },
                        {
                            header: gettext('Name'),
                            dataIndex: 'name',
                            flex: 1,
                            renderer: (v, m, rec) =>
                                rec.data.orphan ? `<i>${gettext('deleted')}</i>` : Ext.htmlEncode(v || ''),
                        },
                        { header: gettext('Node'), dataIndex: 'node', width: 100, renderer: Ext.htmlEncode },
                        {
                            header: gettext('State'),
                            dataIndex: 'state',
                            width: 130,
                            renderer: PVE.cloudprovision.Utils.renderState,
                        },
                        {
                            header: gettext('Template'),
                            dataIndex: 'template',
                            flex: 1,
                            renderer: PVE.cloudprovision.Utils.renderTemplate,
                        },
                        {
                            header: gettext('Created'),
                            dataIndex: 'created',
                            width: 150,
                            renderer: Ext.util.Format.dateRenderer('Y-m-d H:i:s'),
                        },
                        {
                            header: gettext('Reinstalled'),
                            dataIndex: 'reinstalled',
                            width: 150,
                            renderer: Ext.util.Format.dateRenderer('Y-m-d H:i:s'),
                        },
                    ],
                },
                {
                    xtype: 'grid',
                    title: gettext('Templates'),
                    flex: 2,
                    border: false,
                    store: { type: 'diff', rstore: templates, sorters: 'vmid' },
                    columns: [
                        { header: 'VMID', dataIndex: 'vmid', width: 80 },
                        { header: gettext('Name'), dataIndex: 'name', flex: 1, renderer: Ext.htmlEncode },
                        { header: gettext('Node'), dataIndex: 'node', width: 100, renderer: Ext.htmlEncode },
                        { header: gettext('OS type'), dataIndex: 'ostype', width: 80 },
                        {
                            header: gettext('CPU / Memory'),
                            dataIndex: 'cores',
                            width: 130,
                            renderer: (v, m, rec) =>
                                `${rec.data.sockets * rec.data.cores} vCPU, ${rec.data.memory} MiB`,
                        },
                        {
                            header: gettext('Disk'),
                            dataIndex: 'disk-size',
                            width: 140,
                            renderer: (v, m, rec) =>
                                `${Proxmox.Utils.format_size(v || 0)} (${Ext.htmlEncode(rec.data.storage || '-')})`,
                        },
                        {
                            header: 'Cloud-Init',
                            dataIndex: 'cloudinit',
                            width: 80,
                            renderer: Proxmox.Utils.format_boolean,
                        },
                        {
                            header: gettext('Shared'),
                            dataIndex: 'shared',
                            width: 70,
                            renderer: Proxmox.Utils.format_boolean,
                        },
                    ],
                },
            ],
            listeners: {
                destroy: () => {
                    servers.stopUpdate();
                    templates.stopUpdate();
                },
            },
        });

        me.callParent();
        servers.startUpdate();
        templates.startUpdate();
    },
});

// "Create Cloud Server" next to "Create VM" / "Create CT" in the header
Ext.define('PVE.cloudprovision.StdWorkspaceOverride', {
    override: 'PVE.StdWorkspace',

    initComponent: function () {
        let me = this;
        me.callParent(arguments);

        try {
            let header = me.down('container[region=north]');
            let items = header.items;
            let createCT = items.findIndexBy((item) => item.iconCls === 'fa fa-cube');
            let button = Ext.create('Ext.button.Button', {
                pack: 'end',
                margin: '3 5 0 0',
                baseCls: 'x-btn',
                iconCls: 'fa fa-cloud',
                text: gettext('Create Cloud Server'),
                itemId: 'createcloudserver',
                disabled: !PVE.cloudprovision.Utils.canCreate(),
                handler: () => PVE.cloudprovision.Utils.openCreateWizard(),
            });
            header.insert(createCT >= 0 ? createCT + 1 : items.getCount(), button);

            Ext.state.Manager.getProvider().on('statechange', (sp, key, value) => {
                if (key === 'GuiCap' && value) {
                    button.setDisabled(!value.vms['VM.Allocate']);
                }
            });
        } catch (err) {
            console.error('pve-cloudprovision: unable to add header button', err);
        }
    },
});

// ... and in the node context menu
Ext.define('PVE.cloudprovision.NodeCmdMenuOverride', {
    override: 'PVE.node.CmdMenu',

    initComponent: function () {
        let me = this;
        me.callParent(arguments);

        try {
            let createCT = me.getComponent('createct');
            me.insert(me.items.indexOf(createCT) + 1, {
                text: gettext('Create Cloud Server'),
                itemId: 'createcloudserver',
                iconCls: 'fa fa-cloud',
                disabled: !PVE.cloudprovision.Utils.canCreate(),
                handler: function () {
                    PVE.cloudprovision.Utils.openCreateWizard(this.up('menu').nodename);
                },
            });
        } catch (err) {
            console.error('pve-cloudprovision: unable to add menu item', err);
        }
    },
});

// add the panels to the VM and datacenter config views
Ext.define('PVE.cloudprovision.ConfigPanelOverride', {
    override: 'PVE.panel.Config',

    initComponent: function () {
        let me = this;

        let insertAfter = function (item, afterId) {
            let items = me.items || [];
            let pos = items.findIndex((i) => i.itemId === afterId);
            if (pos < 0) {
                items.push(item);
            } else {
                items.splice(pos + 1, 0, item);
            }
            me.items = items;
        };

        try {
            let caps = Ext.state.Manager.get('GuiCap');
            if (me.$className === 'PVE.qemu.Config' && caps.vms['VM.Audit'] && !me.pveSelNode.data.template) {
                insertAfter(
                    {
                        xtype: 'pveCloudProvisionGuestPanel',
                        title: gettext('Cloud Server'),
                        iconCls: 'fa fa-cloud',
                        itemId: 'cloudprovision',
                    },
                    'cloudinit',
                );
            } else if (me.$className === 'PVE.dc.Config' && caps.vms['VM.Audit']) {
                insertAfter(
                    {
                        xtype: 'pveCloudProvisionClusterPanel',
                        title: gettext('Cloud Servers'),
                        iconCls: 'fa fa-cloud',
                        itemId: 'cloudprovision',
                    },
                    'summary',
                );
            }
        } catch (err) {
            console.error('pve-cloudprovision: unable to add panel', err);
        }

        me.callParent(arguments);
    },
});
