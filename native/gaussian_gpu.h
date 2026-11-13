#pragma once
#include "gaussian_shader.h"

struct GaussianRecord {
 double mean[3];
 float covariance[6], dc[3], alpha;
};
struct GaussianVertex {
 float mean[3], covariance[6], dc[3], alpha;
};
static_assert(sizeof(GaussianRecord) == 64 && sizeof(GaussianVertex) == 52);

class GaussianGpu {
 static constexpr unsigned BucketCount = 8192;
 std::array<uint32_t,BucketCount> buckets{};
 std::vector<uint16_t> keys;
 std::vector<uint32_t> ordered;
 Vec3 last_direction{};
 bool has_order = false;

 ComPtr<ID3D11Buffer> order_buffer, harmonic_buffer;
 ComPtr<ID3D11ShaderResourceView> harmonic_view, color_view;
 ComPtr<ID3D11Texture2D> color;
 ComPtr<ID3D11RenderTargetView> color_target;
 ComPtr<ID3D11VertexShader> vertex_shader, resolve_vertex;
 ComPtr<ID3D11GeometryShader> geometry_shader;
 ComPtr<ID3D11PixelShader> pixel_shader, resolve_pixel;
 ComPtr<ID3D11InputLayout> input_layout;
 ComPtr<ID3D11BlendState> blend;
 ComPtr<ID3D11DepthStencilState> no_depth;
 uint32_t width = 0, height = 0;

 static ComPtr<ID3DBlob> compile(const char* entry, const char* target) {
  ComPtr<ID3DBlob> program, errors;
  HRESULT result = D3DCompile(gaussian_shader, strlen(gaussian_shader), nullptr, nullptr, nullptr,
      entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &program, &errors);
  if (FAILED(result) && errors) throw std::runtime_error(static_cast<const char*>(errors->GetBufferPointer()));
  hr(result, entry);
  return program;
 }

 void resize(ID3D11Device* device, uint32_t w, uint32_t h) {
  if (w == width && h == height) return;
  color.Reset(); color_view.Reset(); color_target.Reset();
  D3D11_TEXTURE2D_DESC texture{};
  texture.Width=w; texture.Height=h; texture.MipLevels=1; texture.ArraySize=1;
  texture.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;
  texture.SampleDesc.Count=1;
  texture.BindFlags=D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  hr(device->CreateTexture2D(&texture,nullptr,&color), "Gaussian accumulation texture");
  hr(device->CreateRenderTargetView(color.Get(),nullptr,&color_target), "Gaussian accumulation target");
  hr(device->CreateShaderResourceView(color.Get(),nullptr,&color_view), "Gaussian accumulation view");
  width=w; height=h;
 }

 void order(ID3D11DeviceContext* context, const std::vector<Source>& source, Vec3 direction, const Bounds& bounds) {
  if (has_order && dot(direction,last_direction) > 1.0-1e-12) return;
  double minimum = 0, maximum = 0;
  const double lo[] = {bounds.min.x,bounds.min.y,bounds.min.z};
  const double hi[] = {bounds.max.x,bounds.max.y,bounds.max.z};
  const double components[] = {direction.x,direction.y,direction.z};
  for (int axis=0; axis<3; ++axis) {
   minimum += std::min(lo[axis]*components[axis],hi[axis]*components[axis]);
   maximum += std::max(lo[axis]*components[axis],hi[axis]*components[axis]);
  }
  const double scale = (BucketCount-1) / std::max(1e-12,maximum-minimum);
  buckets.fill(0);
  for (size_t i=0; i<source.size(); ++i) {
   const auto& point = source[i].xyz;
   const double depth = point[0]*direction.x + point[1]*direction.y + point[2]*direction.z;
   const auto key = static_cast<uint16_t>(std::clamp((maximum-depth)*scale,0.0,double(BucketCount-1)));
   keys[i] = key;
   ++buckets[key];
  }
  uint32_t offset=0;
  for (auto& bucket : buckets) {
   const uint32_t count=bucket;
   bucket=offset;
   offset+=count;
  }
  for (uint32_t i=0; i<source.size(); ++i) ordered[buckets[keys[i]]++]=i;
  D3D11_MAPPED_SUBRESOURCE mapped{};
  hr(context->Map(order_buffer.Get(),0,D3D11_MAP_WRITE_DISCARD,0,&mapped), "Gaussian depth order upload");
  memcpy(mapped.pData,ordered.data(),ordered.size()*sizeof(uint32_t));
  context->Unmap(order_buffer.Get(),0);
  last_direction=direction;
  has_order=true;
 }

public:
 void initialize(ID3D11Device* device, uint32_t count, const std::vector<uint16_t>& harmonics) {
  auto vertex=compile("projectSplat","vs_5_0");
  auto geometry=compile("quad","gs_5_0");
  auto pixel=compile("blendSplat","ps_5_0");
  auto resolve_vs=compile("fullScreen","vs_5_0");
  auto resolve_ps=compile("resolveColor","ps_5_0");
  hr(device->CreateVertexShader(vertex->GetBufferPointer(),vertex->GetBufferSize(),nullptr,&vertex_shader), "Gaussian vertex shader");
  hr(device->CreateGeometryShader(geometry->GetBufferPointer(),geometry->GetBufferSize(),nullptr,&geometry_shader), "Gaussian quad shader");
  hr(device->CreatePixelShader(pixel->GetBufferPointer(),pixel->GetBufferSize(),nullptr,&pixel_shader), "Gaussian blend shader");
  hr(device->CreateVertexShader(resolve_vs->GetBufferPointer(),resolve_vs->GetBufferSize(),nullptr,&resolve_vertex), "Gaussian resolve vertex shader");
  hr(device->CreatePixelShader(resolve_ps->GetBufferPointer(),resolve_ps->GetBufferSize(),nullptr,&resolve_pixel), "Gaussian resolve pixel shader");
  D3D11_INPUT_ELEMENT_DESC elements[] = {
    {"POSITION",0,DXGI_FORMAT_R32G32B32_FLOAT,0,0,D3D11_INPUT_PER_VERTEX_DATA,0},
    {"COVARIANCE",0,DXGI_FORMAT_R32G32B32_FLOAT,0,12,D3D11_INPUT_PER_VERTEX_DATA,0},
    {"COVARIANCE",1,DXGI_FORMAT_R32G32B32_FLOAT,0,24,D3D11_INPUT_PER_VERTEX_DATA,0},
    {"COLOR",0,DXGI_FORMAT_R32G32B32A32_FLOAT,0,36,D3D11_INPUT_PER_VERTEX_DATA,0},
  };
  hr(device->CreateInputLayout(elements,4,vertex->GetBufferPointer(),vertex->GetBufferSize(),&input_layout), "Gaussian input layout");
  D3D11_BUFFER_DESC indexes{};
  indexes.ByteWidth=count*sizeof(uint32_t); indexes.Usage=D3D11_USAGE_DYNAMIC;
  indexes.BindFlags=D3D11_BIND_INDEX_BUFFER; indexes.CPUAccessFlags=D3D11_CPU_ACCESS_WRITE;
  hr(device->CreateBuffer(&indexes,nullptr,&order_buffer), "Gaussian depth order buffer");
  ordered.resize(count); keys.resize(count);

  if (!harmonics.empty()) {
   D3D11_BUFFER_DESC coefficients{};
   coefficients.ByteWidth=static_cast<UINT>(harmonics.size()*sizeof(uint16_t));
   coefficients.Usage=D3D11_USAGE_IMMUTABLE;
   coefficients.BindFlags=D3D11_BIND_SHADER_RESOURCE;
   D3D11_SUBRESOURCE_DATA initial{}; initial.pSysMem=harmonics.data();
   hr(device->CreateBuffer(&coefficients,&initial,&harmonic_buffer), "Gaussian spherical harmonics buffer");
   D3D11_SHADER_RESOURCE_VIEW_DESC view{};
   view.Format=DXGI_FORMAT_R16_FLOAT; view.ViewDimension=D3D11_SRV_DIMENSION_BUFFER;
   view.Buffer.NumElements=static_cast<UINT>(harmonics.size());
   hr(device->CreateShaderResourceView(harmonic_buffer.Get(),&view,&harmonic_view), "Gaussian spherical harmonics view");
  }

  D3D11_BLEND_DESC blending{};
  blending.IndependentBlendEnable=true;
  for (int i=0; i<3; ++i) blending.RenderTarget[i].RenderTargetWriteMask=D3D11_COLOR_WRITE_ENABLE_ALL;
  auto& rgba=blending.RenderTarget[0];
  rgba.BlendEnable=true;
  rgba.SrcBlend=rgba.SrcBlendAlpha=D3D11_BLEND_ONE;
  rgba.DestBlend=rgba.DestBlendAlpha=D3D11_BLEND_INV_SRC_ALPHA;
  rgba.BlendOp=rgba.BlendOpAlpha=D3D11_BLEND_OP_ADD;
  hr(device->CreateBlendState(&blending,&blend), "Gaussian alpha blend");
  D3D11_DEPTH_STENCIL_DESC depth{};
  depth.DepthEnable=false; depth.DepthWriteMask=D3D11_DEPTH_WRITE_MASK_ZERO; depth.DepthFunc=D3D11_COMPARISON_ALWAYS;
  hr(device->CreateDepthStencilState(&depth,&no_depth), "Gaussian depth state");
 }

 void render(ID3D11Device* device, ID3D11DeviceContext* context, ID3D11Buffer* vertices, ID3D11Buffer* camera,
             ID3D11RenderTargetView* const* output, const std::vector<Source>& source, Vec3 direction,
             const Bounds& bounds, uint32_t w, uint32_t h) {
  resize(device,w,h);
  order(context,source,direction,bounds);
  constexpr float transparent[4]={};
  context->ClearRenderTargetView(color_target.Get(),transparent);
  ID3D11RenderTargetView* splat_targets[] = {color_target.Get(),output[1],output[2]};
  context->OMSetRenderTargets(3,splat_targets,nullptr);
  context->OMSetDepthStencilState(no_depth.Get(),0);
  context->OMSetBlendState(blend.Get(),nullptr,0xffffffff);
  UINT stride=sizeof(GaussianVertex), offset=0;
  context->IASetVertexBuffers(0,1,&vertices,&stride,&offset);
  context->IASetIndexBuffer(order_buffer.Get(),DXGI_FORMAT_R32_UINT,0);
  context->IASetInputLayout(input_layout.Get());
  context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_POINTLIST);
  context->VSSetShader(vertex_shader.Get(),nullptr,0);
  context->VSSetConstantBuffers(0,1,&camera);
  auto* sh=harmonic_view.Get();
  context->VSSetShaderResources(0,1,&sh);
  context->GSSetShader(geometry_shader.Get(),nullptr,0);
  context->PSSetShader(pixel_shader.Get(),nullptr,0);
  context->DrawIndexed(static_cast<UINT>(source.size()),0,0);

  context->OMSetRenderTargets(1,output,nullptr);
  context->OMSetBlendState(nullptr,nullptr,0xffffffff);
  context->IASetInputLayout(nullptr);
  context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  context->VSSetShader(resolve_vertex.Get(),nullptr,0);
  context->GSSetShader(nullptr,nullptr,0);
  context->PSSetShader(resolve_pixel.Get(),nullptr,0);
  context->PSSetConstantBuffers(0,1,&camera);
  auto* rgb=color_view.Get();
  context->PSSetShaderResources(1,1,&rgb);
  context->Draw(3,0);
  ID3D11ShaderResourceView* empty=nullptr;
  context->PSSetShaderResources(1,1,&empty);
 }
};
