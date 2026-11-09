/* A bounded delimited-text parser: never let CSV input reach workbook sniffing.
 * Values stay strings. Delimiters inside quoted fields and embedded newlines
 * are preserved, and discarded rows/columns are scanned without allocating. */
function tableReadText(text, extension) {
    var delimiter = extension === 'tsv' ? '\t' : ',', directive = /^\uFEFF?sep=(.)\r?\n/.exec(text);
    if (directive) { delimiter = directive[1]; text = text.slice(directive[0].length); }
    else if (extension !== 'tsv') {
        var counts = [0,0,0], choices = [',',';','\t'], quoted = false, lines = 0;
        for (var d=0; d<text.length && lines<10; d++) {
            if (text[d] === '"') { if (quoted && text[d+1] === '"') d++; else quoted=!quoted; }
            else if (!quoted) {
                var which=choices.indexOf(text[d]); if (which>=0) counts[which]++;
                if (text[d] === '\n') lines++;
            }
        }
        delimiter=choices[counts.indexOf(Math.max.apply(null,counts))];
    }
    if (text[0] === '\uFEFF') text=text.slice(1);
    var rows=[], row=[], field='', inQuote=false, atStart=true, touched=false;
    var rowIndex=0, column=0, columns=0, stored=0, characters=0, limited=false;
    function keep() { return rowIndex<100000 && column<512 && stored<2000000; }
    function endField() {
        if (keep()) { row.push(field); stored++; characters+=field.length; }
        else limited=true;
        if (characters>16000000) throw Error('Cell text exceeds preview limit.');
        column++; field=''; atStart=true;
    }
    function endRow() {
        if (rowIndex<100000 && row.length) { rows.push(row); columns=Math.max(columns,row.length); }
        else limited=true;
        row=[]; column=0; rowIndex++; touched=false;
    }
    for (var i=0; i<text.length; i++) {
        var ch=text[i]; touched=true;
        if (inQuote) {
            if (ch === '"') {
                if (text[i+1] === '"') i++;
                else { inQuote=false; continue; }
            }
        } else {
            if (ch === '"' && atStart) { inQuote=true; atStart=false; continue; }
            if (ch === delimiter) { endField(); continue; }
            if (ch === '\r' || ch === '\n') {
                if (ch === '\r' && text[i+1] === '\n') i++;
                endField(); endRow(); continue;
            }
        }
        atStart=false;
        if (keep() && field.length<32768) field+=ch;
        else limited=true;
    }
    if (inQuote) throw Error('Unterminated quoted CSV field.');
    if (touched || column) { endField(); endRow(); }
    var count=Math.min(rows.length,Math.floor(2000000/Math.max(1,columns)));
    if (count<rows.length) limited=true;
    rows=rows.slice(0,count);
    rows.forEach(function(r){while(r.length<columns)r.push('');});
    return {sheets:[{name:'Sheet1',rows:rows,columns:columns,limited:limited}],truncated:limited};
}
