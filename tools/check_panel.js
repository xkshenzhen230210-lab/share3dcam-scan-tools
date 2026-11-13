// Guard the actual panel function against rebuilding accessibility nodes on
// every statistics update. This also parses the complete shipped script.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../extension/share_pointcloud/panel.html'),'utf8');
new vm.Script(source.match(/<script>([\s\S]*?)<\/script>/)[1]);
let created=0,writes=0;
const host={children:[],append(node){node.parent=this;this.children.push(node)},get lastElementChild(){return this.children.at(-1)}};
const context={$:()=>host,document:{createElement(){created++;return {value:'',set textContent(v){writes++;this.value=v},get textContent(){return this.value},remove(){this.parent.children.splice(this.parent.children.indexOf(this),1)}}}}};
vm.createContext(context);vm.runInContext(source.match(/^function renderMetrics.*$/m)[0],context);
for(let i=0;i<200;i++)context.renderMetrics([['原始点',21312301],['提交点',21312301]]);
assert.equal(created,2);assert.equal(writes,2);const first=host.children[0];
context.renderMetrics([['原始点',21312301],['提交点',21312300]]);
assert.equal(host.children[0],first);assert.equal(created,2);assert.equal(writes,3);
context.renderMetrics([]);assert.equal(host.children.length,0);
console.log('Panel syntax and stable metric nodes: PASS');
