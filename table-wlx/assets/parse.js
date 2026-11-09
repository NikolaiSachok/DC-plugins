/* TableView adapter. The decoder is embedded in JavaScriptCore, without DOM,
 * network, filesystem or process APIs. Never evaluate workbook content. */
function tableRead(input, extension) {
    var text = extension === 'csv' || extension === 'tsv';
    if (text) return tableReadText(input, extension);
    var wb = XLSX.read(input, {
        type: 'base64', dense: true, raw: text, cellFormula: false,
        cellHTML: false, cellStyles: false, bookVBA: false,
        sheetRows: 100001, codepage: 65001,
        FS: extension === 'tsv' ? '\t' : undefined
    });
    if (!wb.SheetNames.length) throw Error('No worksheets found.');
    if (wb.SheetNames.length > 128) throw Error('More than 128 worksheets.');
    var sheets = [], budget = 2000000, characters = 0, truncated = false;
    wb.SheetNames.forEach(function(name) {
        var ws = wb.Sheets[name], ref = ws['!fullref'] || ws['!ref'];
        var range = ref ? XLSX.utils.decode_range(ref) : {e:{r:-1,c:-1}};
        // ODF repeated trailing cells can exceed SheetJS's reported !ref.
        var dense = ws['!data'], actualColumns = 0;
        if (dense) Object.keys(dense).forEach(function(key) { actualColumns = Math.max(actualColumns, (dense[key] || []).length); });
        var columnCount = Math.max(range.e.c + 1, actualColumns);
        var rowCount = Math.max(range.e.r + 1, dense ? dense.length : 0);
        var columns = Math.min(512, columnCount);
        var rows = Math.min(100000, rowCount);
        if (columns * rows > budget) rows = Math.floor(budget / Math.max(1, columns));
        var limited = rows < rowCount || columns < columnCount;
        truncated = truncated || limited;
        budget -= rows * columns;
        var data = [];
        for (var r = 0; r < rows; r++) {
            var row = [];
            for (var c = 0; c < columns; c++) {
                var cell = dense ? (dense[r] || [])[c] : ws[XLSX.utils.encode_cell({r:r,c:c})];
                var value = cell ? XLSX.utils.format_cell(cell) : '';
                if (value.length > 32768) { value = value.slice(0, 32768); limited = truncated = true; }
                characters += value.length;
                if (characters > 16000000) throw Error('Cell text exceeds preview limit.');
                row.push(value);
            }
            data.push(row);
        }
        sheets.push({name:name, rows:data, columns:columns, limited:limited});
    });
    return {sheets:sheets, truncated:truncated};
}
