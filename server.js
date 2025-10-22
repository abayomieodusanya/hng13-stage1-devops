const http = require('http');
const PORT = process.env.PORT || 3000;
const server = http.createServer((req,res)=>{
  res.writeHead(200, {'Content-Type':'text/html'});
  res.end('<h1>Hello from Node on port 3000</h1>');
});
server.listen(PORT, '0.0.0.0', ()=> console.log('Listening on', PORT));
