import test from 'node:test';
import assert from 'node:assert/strict';
import * as THREE from 'three';
import {sceneCameraPose} from '../public/scene.js';
test('three-quarter camera shows a physical silhouette and fits all corners on wide or narrow displays',()=>{
 for(const aspect of [.5,1,1.8,3]) {
  const box=new THREE.Box3(new THREE.Vector3(-3,-.6,-3.3),new THREE.Vector3(3,1.2,3.3));
  const pose=sceneCameraPose(box,aspect),camera=new THREE.PerspectiveCamera(35,aspect,.01,200);
  camera.position.copy(pose.position);camera.lookAt(pose.target);camera.updateMatrixWorld();
  assert.ok(Math.abs(camera.position.x-pose.target.x)>2,'The default view must not look straight down the fuselage');
  assert.ok(camera.position.y>pose.target.y,'The view must show the wings from above');
  for(const x of [box.min.x,box.max.x])for(const y of [box.min.y,box.max.y])for(const z of [box.min.z,box.max.z]) {
   const clip=new THREE.Vector3(x,y,z).project(camera);
   assert.ok(Math.abs(clip.x)<1&&Math.abs(clip.y)<1&&clip.z<1,'A physical part must not be cropped by camera fitting');
  }
 }
});
