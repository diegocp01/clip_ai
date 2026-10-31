import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

export const sample = {
  title: 'Why water has a bend',
  reply: 'Two hydrogen atoms bond to one oxygen atom. Water has a bent shape, with an angle of about 104.5° between the bonds.',
  cards: [], diagram: { nodes: [], links: [] },
  scene: { objects: [
    { id: 'oxygen', label: 'Oxygen', description: 'The oxygen atom attracts the shared electrons more strongly than hydrogen. Its two lone pairs help give water its bent shape.', shape: 'sphere', color: '#E07855', position: [0, .45, 0], scale: [.95, .95, .95], rotation: [0, 0, 0] },
    { id: 'hydrogen-1', label: 'Hydrogen', description: 'One of two hydrogen atoms bonded to oxygen. This side of the molecule is slightly positively charged.', shape: 'sphere', color: '#B6C7D3', position: [-1.5, -.72, .1], scale: [.64, .64, .64], rotation: [0, 0, 0] },
    { id: 'hydrogen-2', label: 'Hydrogen', description: 'The second hydrogen atom. The angle between the two oxygen–hydrogen bonds is about 104.5°.', shape: 'sphere', color: '#B6C7D3', position: [1.5, -.72, .1], scale: [.64, .64, .64], rotation: [0, 0, 0] },
    { id: 'bond-1', label: 'O–H bond', description: 'A polar covalent bond: oxygen and hydrogen share electrons unequally.', shape: 'cylinder', color: '#E9DFCA', position: [-.73, -.12, .05], scale: [.17, 1.5, .17], rotation: [0, 0, -.91] },
    { id: 'bond-2', label: 'O–H bond', description: 'A polar covalent bond: oxygen and hydrogen share electrons unequally.', shape: 'cylinder', color: '#E9DFCA', position: [.73, -.12, .05], scale: [.17, 1.5, .17], rotation: [0, 0, .91] },
  ] },
};

const shapes = {
  sphere: () => new THREE.SphereGeometry(1, 48, 32),
  box: () => new THREE.BoxGeometry(1, 1, 1),
  cylinder: () => new THREE.CylinderGeometry(1, 1, 1, 40),
  cone: () => new THREE.ConeGeometry(1, 1, 40),
  torus: () => new THREE.TorusGeometry(1, .22, 20, 64),
};

export function createScene(host, onSelect) {
  let renderer;
  try { renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true }); }
  catch {
    const message = document.createElement('p'); message.className = 'scene-fallback';
    message.textContent = '3D rendering is unavailable in this browser. Your explanations and diagrams still work. Try a browser with WebGL enabled.'; host.append(message);
    return { update() {}, reset() {}, clearSelection() {}, hitTest() { return false; }, locate() { return null; }, orbit() {}, zoom() {} };
  }
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.5;
  host.append(renderer.domElement);
  renderer.domElement.setAttribute('aria-label', '3D model. Drag to orbit, scroll to zoom, or choose a labeled part.');
  const labels = document.createElement('div'); labels.className = 'scene-labels'; host.append(labels);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(35, 1, .01, 200);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = !matchMedia('(prefers-reduced-motion: reduce)').matches;
  controls.dampingFactor = .08;
  controls.enablePan = false;
  controls.minDistance = .4;
  controls.maxDistance = 100;
  scene.add(new THREE.HemisphereLight(0xfff8e8, 0x8b8297, 2.3));
  const main = new THREE.DirectionalLight(0xfff1d8, 3.3); main.position.set(-4, 7, 6); scene.add(main);
  const rim = new THREE.DirectionalLight(0xffffff, 2.2); rim.position.set(5, 2, -4); scene.add(rim);
  const fill = new THREE.DirectionalLight(0xcbdcf2, 1.1); fill.position.set(3, -1, 5); scene.add(fill);
  let meshes = [], badges = [], selected = null;
  const group = new THREE.Group(); scene.add(group);
  const raycaster = new THREE.Raycaster(); const pointer = new THREE.Vector2();
  const projected = new THREE.Vector3();
  let pointerStart = null;
  function hitTest(clientX, clientY) {
    if (!Number.isFinite(clientX) || !Number.isFinite(clientY) || !meshes.length) return false;
    const rect = renderer.domElement.getBoundingClientRect();
    if (!rect.width || !rect.height || host.hidden || getComputedStyle(host).visibility === 'hidden') return false;
    if (clientX < rect.left || clientX > rect.right || clientY < rect.top || clientY > rect.bottom) return false;
    pointer.set((clientX - rect.left) / rect.width * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1);
    scene.updateMatrixWorld(true); camera.updateMatrixWorld(true);
    raycaster.setFromCamera(pointer, camera);
    return raycaster.intersectObjects(meshes, false).length > 0;
  }
  function select(mesh) {
    if (selected) selected.material.emissive.setHex(0x000000);
    selected = mesh;
    if (selected) selected.material.emissive.setHex(0x24130b);
    for (const badge of badges) badge.element.classList.toggle('selected', badge.mesh === mesh);
    if (mesh) onSelect(mesh.userData.part);
  }
  renderer.domElement.addEventListener('pointerdown', e => { pointerStart = [e.clientX, e.clientY]; });
  renderer.domElement.addEventListener('pointerup', e => {
    if (!pointerStart || Math.hypot(e.clientX - pointerStart[0], e.clientY - pointerStart[1]) > 6) return;
    pointerStart = null; const rect = renderer.domElement.getBoundingClientRect();
    pointer.set((e.clientX - rect.left) / rect.width * 2 - 1, -((e.clientY - rect.top) / rect.height) * 2 + 1);
    raycaster.setFromCamera(pointer, camera); const hits = raycaster.intersectObjects(meshes);
    if (hits.length) select(hits[0].object);
  });
  function reset() {
    if (!meshes.length) return;
    const box = new THREE.Box3().setFromObject(group);
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const fov = THREE.MathUtils.degToRad(camera.fov);
    const distance = Math.max(size.y, size.x / camera.aspect, size.z) / (2 * Math.tan(fov / 2)) * 1.35 + size.z / 2;
    camera.position.copy(center).add(new THREE.Vector3(distance * .18, distance * .16, distance));
    controls.target.copy(center); controls.update();
  }
  // Where a part sits on screen right now, and about how big it looks.
  function locate(id) {
    const mesh = meshes.find(item => item.userData.part.id === id);
    if (!mesh || host.hidden || !host.clientWidth) return null;
    const rect = host.getBoundingClientRect();
    // The camera may have just moved, and the marks must not lag a frame behind the model.
    camera.updateMatrixWorld();
    projected.copy(mesh.position).project(camera);
    if (projected.z > 1 || projected.z < -1) return null;
    const x = (projected.x * .5 + .5) * rect.width + rect.left, y = (-projected.y * .5 + .5) * rect.height + rect.top;
    const size = Math.max(mesh.scale.x, mesh.scale.y, mesh.scale.z) * .6;
    const distance = camera.position.distanceTo(mesh.position) || 1;
    const r = size / (distance * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2)) * rect.height / 2;
    return { x, y, r: Math.min(Math.max(r, 12), 90) };
  }
  const offset = new THREE.Vector3(), spherical = new THREE.Spherical();
  function orbit(yaw, pitch) {
    offset.copy(camera.position).sub(controls.target); spherical.setFromVector3(offset);
    spherical.theta -= yaw; spherical.phi = Math.min(Math.max(spherical.phi + pitch, .08), Math.PI - .08);
    camera.position.copy(controls.target).add(offset.setFromSpherical(spherical)); camera.lookAt(controls.target);
  }
  function zoom(factor) {
    offset.copy(camera.position).sub(controls.target);
    const length = Math.min(Math.max(offset.length() / factor, controls.minDistance), controls.maxDistance);
    camera.position.copy(controls.target).add(offset.setLength(length));
  }
  function resize() {
    const width = host.clientWidth, height = host.clientHeight;
    if (!width || !height) return;
    renderer.setSize(width, height, false); camera.aspect = width / height; camera.updateProjectionMatrix();
  }
  const observer = new ResizeObserver(() => { resize(); reset(); }); observer.observe(host);
  function update(objects, isSample = false, preserveCamera = false, preview = false) {
    selected = null;
    for (const mesh of meshes) { group.remove(mesh); mesh.geometry.dispose(); mesh.material.dispose(); }
    meshes = []; badges = []; labels.replaceChildren();
    for (const part of objects) {
      const geometry = (shapes[part.shape] || shapes.sphere)();
      const material = new THREE.MeshStandardMaterial({ color: part.color, roughness: .32, metalness: .06 });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.position.fromArray(part.position); mesh.scale.fromArray(part.scale); mesh.rotation.set(...part.rotation);
      mesh.userData.part = part; group.add(mesh); meshes.push(mesh);
      if (!part.label || (isSample && part.id.startsWith('bond'))) continue;
      const badge = document.createElement('button'); badge.className = 'scene-label'; badge.textContent = part.label;
      badge.setAttribute('aria-label', `Inspect ${part.label}`); badge.addEventListener('click', () => select(mesh));
      labels.append(badge); badges.push({ element: badge, mesh });
    }
    resize();
    if(!preserveCamera){
      if(preview){camera.position.set(1.5,1.2,18);controls.target.set(0,0,0);controls.update();}
      else reset();
    }
  }
  function frame() {
    requestAnimationFrame(frame);
    if (!host.clientWidth || !host.clientHeight || document.hidden) return;
    controls.update();
    for (const badge of badges) {
      projected.copy(badge.mesh.position);
      projected.y += Math.max(.2, badge.mesh.scale.y) * .85 + .25;
      projected.project(camera);
      badge.element.style.left = `${(projected.x * .5 + .5) * host.clientWidth}px`;
      badge.element.style.top = `${(-projected.y * .5 + .5) * host.clientHeight}px`;
      badge.element.hidden = projected.z > 1 || projected.z < -1;
    }
    renderer.render(scene, camera);
  }
  resize(); frame();
  return { update, reset, clearSelection: () => select(null), hitTest, locate, orbit, zoom };
}

const ns = 'http://www.w3.org/2000/svg';
function svgElement(tag, attrs = {}, text) {
  const element = document.createElementNS(ns, tag);
  for (const [key, value] of Object.entries(attrs)) element.setAttribute(key, String(value));
  if (text != null) element.textContent = text;
  return element;
}
export function renderDiagram(host, diagram, onSelect) {
  host.replaceChildren();
  const svg = svgElement('svg', { viewBox: '0 0 1000 600', role: 'img', 'aria-label': 'Generated explanation diagram' });
  const defs = svgElement('defs'); const marker = svgElement('marker', { id: 'diagram-arrow', viewBox: '0 0 10 10', refX: '8', refY: '5', markerWidth: '5', markerHeight: '5', orient: 'auto-start-reverse' });
  marker.append(svgElement('path', { d: 'M 0 0 L 10 5 L 0 10 z', fill: '#b7a48b' })); defs.append(marker); svg.append(defs);
  const points = new Map(diagram.nodes.map(n => [n.id, { ...n, px: 90 + n.x * 8.2, py: 55 + n.y * 4.9 }]));
  for (const link of diagram.links) {
    const a = points.get(link.from), b = points.get(link.to); if (!a || !b) continue;
    const dx = b.px - a.px, dy = b.py - a.py, len = Math.hypot(dx, dy) || 1;
    const ax = a.px + dx / len * 48, ay = a.py + dy / len * 33, bx = b.px - dx / len * 49, by = b.py - dy / len * 34;
    svg.append(svgElement('path', { d: `M ${ax} ${ay} L ${bx} ${by}`, stroke: '#b7a48b', 'stroke-width': 2, fill: 'none', 'marker-end': 'url(#diagram-arrow)' }));
    if (link.label) {
      const text = svgElement('text', { x: (a.px + b.px) / 2, y: (a.py + b.py) / 2 - 8, 'text-anchor': 'middle', fill: '#85765f', 'font-size': 13, 'paint-order': 'stroke', stroke: '#fcfbf7', 'stroke-width': 5 }, link.label);
      svg.append(text);
    }
  }
  for (const node of points.values()) {
    const g = svgElement('g', { tabindex: 0, role: 'button', 'aria-label': `Ask about ${node.label}`, style: 'cursor:pointer', 'data-part': node.id });
    g.append(svgElement('rect', { x: node.px - 76, y: node.py - 29, width: 152, height: 58, rx: 13, fill: node.color, 'fill-opacity': .13, stroke: node.color, 'stroke-width': 1.4 }));
    const text = svgElement('text', { x: node.px, y: node.py + 5, 'text-anchor': 'middle', fill: '#484035', 'font-size': 14, 'font-family': '-apple-system, sans-serif' });
    const words = node.label.split(' '); let line = '', lines = [];
    for (const word of words) { if ((line + word).length > 18 && line) { lines.push(line.trim()); line = ''; } line += `${word} `; } if (line) lines.push(line.trim());
    if (lines.length <= 1) text.textContent = node.label;
    else lines.slice(0, 2).forEach((line, i) => text.append(svgElement('tspan', { x: node.px, y: node.py - 5 + i * 18 }, line)));
    g.append(text); g.addEventListener('click', () => onSelect({ id: node.id, label: node.label, description: 'Select below to explore this part of the diagram.' }));
    g.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); g.dispatchEvent(new MouseEvent('click')); } });
    svg.append(g);
  }
  host.append(svg);
}
