#include <wsl/winadapter.h>
#include <wsl/wrladapter.h>
#include <directx/d3d12.h>
#include <directx/dxcore.h>
#include <dxguids/dxguids.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <thread>

using Microsoft::WRL::ComPtr;

static void check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        std::fprintf(stderr, "%s failed: 0x%08x\n", operation, static_cast<unsigned>(result));
        throw std::runtime_error(operation);
    }
}

int main(int argc, char** argv) {
    try {
        if (argc != 3) {
            std::fprintf(stderr, "usage: gpu-probe VENDOR_HEX DEVICE_HEX\n");
            return 2;
        }
        auto parse_id = [](const char* argument) {
            const std::string text(argument);
            if (text.size() != 4 || text.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos)
                throw std::runtime_error("GPU identifiers must contain four hexadecimal digits");
            return static_cast<unsigned>(std::stoul(text, nullptr, 16));
        };
        const unsigned vendor = parse_id(argv[1]);
        const unsigned device_id = parse_id(argv[2]);
        ComPtr<IDXCoreAdapterFactory> factory;
        check(DXCoreCreateAdapterFactory(factory.GetAddressOf()), "DXCoreCreateAdapterFactory");
        ComPtr<IDXCoreAdapterList> adapters;
        check(factory->CreateAdapterList(1, &DXCORE_ADAPTER_ATTRIBUTE_D3D12_GRAPHICS,
                                        adapters.GetAddressOf()), "CreateAdapterList");
        if (adapters->GetAdapterCount() > 128) throw std::runtime_error("adapter count exceeds safety limit");
        ComPtr<IDXCoreAdapter> selected;
        unsigned matches = 0;
        for (uint32_t i = 0; i < adapters->GetAdapterCount(); ++i) {
            ComPtr<IDXCoreAdapter> adapter;
            check(adapters->GetAdapter(i, adapter.GetAddressOf()), "GetAdapter");
            DXCoreHardwareID hardware{};
            bool is_hardware = false;
            check(adapter->GetProperty(DXCoreAdapterProperty::HardwareID, &hardware), "HardwareID");
            check(adapter->GetProperty(DXCoreAdapterProperty::IsHardware, &is_hardware), "IsHardware");
            std::printf("LIMIAR_GPU_ADAPTER vendor=%04x device=%04x hardware=%u\n",
                        hardware.vendorID, hardware.deviceID, is_hardware ? 1 : 0);
            if (is_hardware && hardware.vendorID == vendor && hardware.deviceID == device_id) {
                selected = adapter;
                ++matches;
            }
        }
        if (matches != 1) throw std::runtime_error("expected exactly one matching hardware GPU");
        ComPtr<ID3D12Device> device;
        check(D3D12CreateDevice(selected.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)), "D3D12CreateDevice");
        D3D12_COMMAND_QUEUE_DESC queue_desc{};
        queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        ComPtr<ID3D12CommandQueue> queue;
        check(device->CreateCommandQueue(&queue_desc, IID_PPV_ARGS(&queue)), "CreateCommandQueue");
        ComPtr<ID3D12CommandAllocator> allocator;
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)), "CreateCommandAllocator");
        ComPtr<ID3D12GraphicsCommandList> list;
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&list)), "CreateCommandList");

        D3D12_HEAP_PROPERTIES gpu_heap{};
        gpu_heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        gpu_heap.CreationNodeMask = 1;
        gpu_heap.VisibleNodeMask = 1;
        D3D12_RESOURCE_DESC texture_desc{};
        texture_desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        texture_desc.Width = 64;
        texture_desc.Height = 64;
        texture_desc.DepthOrArraySize = 1;
        texture_desc.MipLevels = 1;
        texture_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        texture_desc.SampleDesc.Count = 1;
        texture_desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        ComPtr<ID3D12Resource> texture;
        check(device->CreateCommittedResource(&gpu_heap, D3D12_HEAP_FLAG_NONE, &texture_desc,
                D3D12_RESOURCE_STATE_RENDER_TARGET, nullptr, IID_PPV_ARGS(&texture)), "CreateTexture");
        D3D12_DESCRIPTOR_HEAP_DESC rtv_desc{};
        rtv_desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        rtv_desc.NumDescriptors = 1;
        ComPtr<ID3D12DescriptorHeap> rtv_heap;
        check(device->CreateDescriptorHeap(&rtv_desc, IID_PPV_ARGS(&rtv_heap)), "CreateDescriptorHeap");
        const auto rtv = rtv_heap->GetCPUDescriptorHandleForHeapStart();
        device->CreateRenderTargetView(texture.Get(), nullptr, rtv);

        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
        UINT64 total_bytes = 0;
        device->GetCopyableFootprints(&texture_desc, 0, 1, 0, &footprint, nullptr, nullptr, &total_bytes);
        D3D12_RESOURCE_DESC buffer_desc{};
        buffer_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        buffer_desc.Width = total_bytes;
        buffer_desc.Height = 1;
        buffer_desc.DepthOrArraySize = 1;
        buffer_desc.MipLevels = 1;
        buffer_desc.SampleDesc.Count = 1;
        buffer_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        auto cpu_heap = gpu_heap;
        cpu_heap.Type = D3D12_HEAP_TYPE_READBACK;
        ComPtr<ID3D12Resource> readback;
        check(device->CreateCommittedResource(&cpu_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
                D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback)), "CreateReadback");
        const float color[4] = {1, 0, 0, 1};
        list->ClearRenderTargetView(rtv, color, 0, nullptr);
        D3D12_RESOURCE_BARRIER barrier{};
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition.pResource = texture.Get();
        barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        list->ResourceBarrier(1, &barrier);
        D3D12_TEXTURE_COPY_LOCATION source{};
        source.pResource = texture.Get();
        source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_TEXTURE_COPY_LOCATION destination{};
        destination.pResource = readback.Get();
        destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        destination.PlacedFootprint = footprint;
        list->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
        check(list->Close(), "CloseCommandList");
        ID3D12CommandList* lists[] = {list.Get()};
        queue->ExecuteCommandLists(1, lists);
        ComPtr<ID3D12Fence> fence;
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "CreateFence");
        check(queue->Signal(fence.Get(), 1), "Signal");
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (fence->GetCompletedValue() != 1) {
            check(device->GetDeviceRemovedReason(), "GetDeviceRemovedReason");
            if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("GPU fence timeout");
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        D3D12_RANGE range{0, static_cast<SIZE_T>(total_bytes)};
        void* mapping = nullptr;
        check(readback->Map(0, &range, &mapping), "MapReadback");
        const auto* bytes = static_cast<const unsigned char*>(mapping);
        unsigned verified = 0;
        for (unsigned y = 0; y < 64; ++y) {
            for (unsigned x = 0; x < 64; ++x) {
                const auto* pixel = bytes + footprint.Offset + y * footprint.Footprint.RowPitch + x * 4;
                if (pixel[0] != 255 || pixel[1] != 0 || pixel[2] != 0 || pixel[3] != 255)
                    throw std::runtime_error("GPU pixel mismatch");
                ++verified;
            }
        }
        D3D12_RANGE no_writes{0, 0};
        readback->Unmap(0, &no_writes);
        std::printf("LIMIAR_GPU_RENDER api=d3d12-clear-readback vendor=%04x device=%04x pixels=%u\n",
                    vendor, device_id, verified);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "LIMIAR_GPU_RENDER_FAILED %s\n", error.what());
        return 1;
    }
}
