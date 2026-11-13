use std::{path::PathBuf, sync::{Arc, atomic::{AtomicU64, Ordering}}, net::Ipv4Addr};
use atv_core::AtvDelegate;
use tokio::{net::TcpListener, io::{AsyncReadExt,AsyncWriteExt}};
use tokio_rustls::{TlsAcceptor,rustls::{ServerConfig,pki_types::{CertificateDer,PrivatePkcs8KeyDer}}};
pub fn directory()->PathBuf {PathBuf::from(std::env::var_os("TVREMOTE_APP_SUPPORT_DIR").unwrap_or_default())}
pub fn enabled()->bool {if std::env::var_os("TVREMOTE_ENABLE_MOTION_PAGE").is_none(){return false;}std::fs::read_to_string(directory().join("pointer-source.txt")).map(|s|s.trim()=="gyro").unwrap_or(false)}
pub fn start(delegate:Arc<dyn AtvDelegate>,ip:Ipv4Addr){tokio::spawn(async move {if let Err(e)=serve(delegate,ip).await {tracing::error!("motion service: {e}");}});}
async fn serve(delegate:Arc<dyn AtvDelegate>,ip:Ipv4Addr)->Result<(),Box<dyn std::error::Error+Send+Sync>> {
 let dir=directory(); std::fs::create_dir_all(&dir)?;
 let token_path=dir.join("motion-token.txt");let token=match std::fs::read_to_string(&token_path){Ok(v)=>v,Err(_)=>{let v=format!("{}{}",rand_id(),rand_id());std::fs::write(&token_path,&v)?;v}};
 let cert_path=dir.join("motion-cert.der");let key_path=dir.join("motion-key.der");
 let (cert,key)=if cert_path.exists()&&key_path.exists()&&std::fs::read_to_string(dir.join("motion-ip.txt")).unwrap_or_default()==ip.to_string(){(std::fs::read(cert_path)?,std::fs::read(key_path)?)}else{let rcgen::CertifiedKey{cert,key_pair}=rcgen::generate_simple_self_signed(vec![ip.to_string(),"localhost".into()])?;let c=cert.der().to_vec();let k=key_pair.serialize_der();std::fs::write(&cert_path,&c)?;std::fs::write(&key_path,&k)?;(c,k)};
 std::fs::write(dir.join("motion-ip.txt"),ip.to_string())?;
 let config=ServerConfig::builder().with_no_client_auth().with_single_cert(vec![CertificateDer::from(cert)],PrivatePkcs8KeyDer::from(key).into())?;
 let listener=TcpListener::bind((Ipv4Addr::UNSPECIFIED,19443)).await?;let acceptor=TlsAcceptor::from(Arc::new(config));
 std::fs::write(dir.join("motion-url.txt"),format!("https://{ip}:19443/?token={token}"))?;
 tracing::info!("motion service listening on {ip}:19443");
 let samples=Arc::new(AtomicU64::new(0));
 let drag=Arc::new(std::sync::Mutex::new(None::<std::time::Instant>));
 let lease=drag.clone();let controller=delegate.clone();
 tokio::spawn(async move {loop{tokio::time::sleep(std::time::Duration::from_millis(200)).await;let mut state=lease.lock().unwrap();if state.map(|t|t.elapsed().as_secs_f64()>0.8).unwrap_or(false){controller.on_drag(false,0.0,0.0);*state=None;}}});
 loop {let (stream,peer)=listener.accept().await?;let samples=samples.clone();let drag=drag.clone();let a=acceptor.clone();let d=delegate.clone();let t=token.clone();tokio::spawn(async move {let _=tokio::time::timeout(std::time::Duration::from_secs(5),async move {
 let mut stream=a.accept(stream).await?;let mut bytes=Vec::new();let mut buf=[0;2048];let end;
 loop {let n=stream.read(&mut buf).await?;if n==0{return Ok::<(),std::io::Error>(());}bytes.extend_from_slice(&buf[..n]);if bytes.len()>8192{return Ok(());}if let Some(pos)=bytes.windows(4).position(|w|w==b"\r\n\r\n"){end=pos+4;break;}}
 let headers=String::from_utf8_lossy(&bytes[..end]);let first=headers.lines().next().unwrap_or("");let get=first==format!("GET /?token={t} HTTP/1.1");
 let authorized=headers.lines().any(|line|line.split_once(':').map(|(k,v)|k.eq_ignore_ascii_case("x-motion-token")&&v.trim()==t).unwrap_or(false));
 let length=headers.lines().find_map(|l|{let(k,v)=l.split_once(':')?;if k.eq_ignore_ascii_case("content-length"){v.trim().parse::<usize>().ok()}else{None}}).unwrap_or(0);
 if length>4096{return Ok(());}let post=first=="POST /input HTTP/1.1"&&authorized;
 let (code,kind,body)=if get{tracing::info!("motion capture page opened by {}",peer.ip());("200 OK","text/html; charset=utf-8",include_str!("motion.html").to_owned())}else if post{
 while bytes.len()<end+length {let n=stream.read(&mut buf).await?;if n==0{return Ok(());}bytes.extend_from_slice(&buf[..n]);}
 if let Ok(v)=serde_json::from_slice::<serde_json::Value>(&bytes[end..end+length]){let x=v["dx"].as_f64().unwrap_or(0.0);let y=v["dy"].as_f64().unwrap_or(0.0);if x.is_finite()&&y.is_finite() {match v["kind"].as_str(){Some("gyro")=>{let n=samples.fetch_add(1,Ordering::Relaxed)+1;if n==1||n%120==0{tracing::info!("motion gyro samples={n} source_enabled={}",enabled());}d.on_gyro(x.clamp(-100.0,100.0),y.clamp(-100.0,100.0))},Some("drag")=>{if let Some(active)=v["active"].as_bool(){let mut lease=drag.lock().unwrap();d.on_drag(active,x.clamp(-100.0,100.0),y.clamp(-100.0,100.0));*lease=if active{Some(std::time::Instant::now())}else{None};}},Some("touch")=>d.on_touch(x.clamp(-100.0,100.0),y.clamp(-100.0,100.0),atv_core::TouchPhase::Moved),Some("button")=>{if let Some(b)=v["button"].as_str(){if matches!(b,"select"|"two_finger_tap"|"three_finger_tap"|"four_finger_tap"|"menu"|"home"|"toggle_scroll"|"motion_left"|"motion_right"|"motion_up"|"motion_down"|"motion_zoom_in"|"motion_zoom_out"){d.on_button(b);}}},Some("scroll")=>d.on_scroll(x.clamp(-100.0,100.0),y.clamp(-100.0,100.0)),_=>{}}}}
 ("200 OK","application/json","{}".into())}else{("403 Forbidden","text/plain","Invalid session".into())};
 let reply=format!("HTTP/1.1 {code}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n{body}",body.len());stream.write_all(reply.as_bytes()).await?;stream.shutdown().await?;Ok(())}).await;});}
}
fn rand_id()->String {format!("{:016x}",rand::random::<u64>())}
