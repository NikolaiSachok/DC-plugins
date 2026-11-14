/* Offline fixtures for the real-artifact harness. */
const fs = require('fs'), path = require('path');
const XLSX = require('../assets/xlsx.full.min.js');
const dir = process.argv[2] || 'build/samples';
fs.mkdirSync(dir, {recursive:true});
const data = [['Name','Count','Notes'],['Alpha',42,'A, B'],['Beta',0,'line one\nline two'],['00123',-2,'<script>alert(1)</script>']];
const wb = XLSX.utils.book_new();
const ws = XLSX.utils.aoa_to_sheet(data);
ws.B5={t:'n',v:45292,z:'yyyy-mm-dd'};
ws.C5={t:'n',v:12.5,z:'$0.00'};
ws.A5={t:'n',v:84,f:'B2*2'};
ws['!ref']='A1:C5';
XLSX.utils.book_append_sheet(wb,ws,'First');
XLSX.utils.book_append_sheet(wb,XLSX.utils.aoa_to_sheet([['Other sheet'],['second value']]),'Second');
for (const type of ['xlsx','xlsm','xlsb','xls','ods','fods','dif','sylk','dbf']) {
    const ext=type==='sylk'?'slk':type;
    const source=type==='sylk'?JSON.parse(JSON.stringify(wb)):wb;
    if(type==='sylk') source.Sheets.First.C3.v='single line'; // SYLK has no multiline string syntax.
    fs.writeFileSync(path.join(dir,'sample.'+ext), XLSX.write(source,{bookType:type,type:'buffer',compression:true}));
}
fs.writeFileSync(path.join(dir,'sample.csv'),'Name,Count,Notes\r\nAlpha,42,"A, B"\r\nBeta,0,"line one\nline two"\r\n00123,-2,"<script>alert(1)</script>"\r\n');
fs.writeFileSync(path.join(dir,'semicolon.csv'),'Name;Count;Notes\r\nAlpha;42;A, B\r\n');
fs.writeFileSync(path.join(dir,'sample.tsv'),'Name\tCount\tNotes\nAlpha\t42\tA, B\n');
fs.writeFileSync(path.join(dir,'utf16.tsv'),Buffer.concat([Buffer.from([255,254]),Buffer.from('Name\tCount\nČeský\t42\n','utf16le')]));
fs.writeFileSync(path.join(dir,'cp1252.csv'),Buffer.from('Name,Count\nCaf\xe9,42\n','latin1'));
fs.writeFileSync(path.join(dir,'empty.csv'),'');
fs.writeFileSync(path.join(dir,'broken.xlsx'),'PK\u0003\u0004broken');
fs.writeFileSync(path.join(dir,'other.txt'),'fall through');
fs.writeFileSync(path.join(dir,'large.csv'),'Name,Count\n'+Array.from({length:110000},(_,i)=>`Row ${i},${i}`).join('\n'));
const nw = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(nw,XLSX.utils.aoa_to_sheet([['Name','Count'],['Apple sample',42]]),'Apple');
fs.writeFileSync(path.join(dir,'sample.numbers'),XLSX.write(nw,{type:'buffer',bookType:'numbers',numbers:require('./fixtures/xlsx.zahl.js'),compression:true}));
console.log('Generated table fixtures in '+dir);

fs.writeFileSync(path.join(dir,'quotes.csv'),'ID,Value,Empty\r\n007,"He said ""hello""",\r\n008,"a\tb",\r\n');
fs.writeFileSync(path.join(dir,'directive.csv'),'sep=;\nName;Count\nAlpha;42\n');
fs.writeFileSync(path.join(dir,'wide.csv'),Array(1000000).fill('x').join(','));
fs.writeFileSync(path.join(dir,'long.csv'),'x'.repeat(40000));
fs.writeFileSync(path.join(dir,'incomplete.csv'),'Name,Value\nAlpha,"unfinished');

const description='A long example record with a complete description that extends beyond the default column width. Drag the column divider to skim the column, or read the selected value in the panel below the grid.';
fs.writeFileSync(path.join(dir,'details.csv'),'ID,Description,Notes\n001,"'+description+'","First line\nSecond line\nThird line\nFourth line\nFifth line\nLast line: end of record"\n002,"Another long description that is easy to scan when the Description column is made wider.",Short note\n');

// Two-axis scrolling fixture for frozen header verification.
fs.writeFileSync(path.join(dir,'headers.csv'),Array.from({length:80},(_,r)=>Array.from({length:12},(_,c)=>`R${r}C${c}`).join(',')).join('\n'));
