#include <nan.h>
extern "C"
{
#include "miner.h"
}

class MinerWorker : public Nan::AsyncWorker
{
public:
  MinerWorker(Nan::Callback *callback, worker_t *worker, uint32_t start_nonce, uint32_t share_compact)
      : AsyncWorker(callback), worker(worker), start_nonce(start_nonce), share_compact(share_compact), result_nonce(0) {}
  ~MinerWorker() {}

  void Execute()
  {
    cl_int ret = mine_nonces(worker, start_nonce, share_compact, &result_nonce);
    if (ret != CL_SUCCESS)
    {
      this->SetErrorMessage("MineNonces() failed.");
    }
  }

  void HandleOKCallback()
  {
    Nan::HandleScope scope;
    v8::Local<v8::Value> argv[] = {
      Nan::Null(),
      Nan::New<v8::Number>(result_nonce)
    };
    callback->Call(2, argv, async_resource);
  }

  void HandleErrorCallback()
  {
    Nan::HandleScope scope;
    v8::Local<v8::Value> argv[] = {
        Nan::New(this->ErrorMessage()).ToLocalChecked(),
        Nan::Null()
    };
    callback->Call(2, argv, async_resource);
  }

private:
  worker_t *worker;
  uint32_t start_nonce;
  uint32_t share_compact;
  uint32_t result_nonce;
};


class Miner : public Nan::ObjectWrap
{
public:
  static NAN_MODULE_INIT(Init)
  {
    v8::Local<v8::FunctionTemplate> tpl = Nan::New<v8::FunctionTemplate>(New);
    tpl->SetClassName(Nan::New("Miner").ToLocalChecked());
    tpl->InstanceTemplate()->SetInternalFieldCount(1);

    Nan::SetPrototypeMethod(tpl, "getWorkers", GetWorkers);

    constructor().Reset(Nan::GetFunction(tpl).ToLocalChecked());
    Nan::Set(target, Nan::New("Miner").ToLocalChecked(), Nan::GetFunction(tpl).ToLocalChecked());
  }

private:
  explicit Miner(miner_t miner) : miner(miner) {}

  ~Miner()
  {
    release_miner(&miner);
  }

  static NAN_METHOD(New)
  {
    if (!info.IsConstructCall())
    {
      return Nan::ThrowError(Nan::New("Miner() must be called with new keyword.").ToLocalChecked());
    }

    // GPU to use
    v8::Local<v8::Array> allowedDevicesArray = v8::Local<v8::Array>::Cast(info[0]);
    uint32_t *allowedDevices = new uint32_t[allowedDevicesArray->Length()];
    for (uint32_t i = 0; i < allowedDevicesArray->Length(); i++) {
      allowedDevices[i] = Nan::To<uint32_t>(allowedDevicesArray->Get(i)).FromJust();
    }
    // Allocated memory for each GPU (in MB)
    v8::Local<v8::Array> memorySizesArray = v8::Local<v8::Array>::Cast(info[1]);
    uint32_t *memorySizes = new uint32_t[memorySizesArray->Length()];
    for (uint32_t i = 0; i < memorySizesArray->Length(); i++) {
      memorySizes[i] = Nan::To<uint32_t>(memorySizesArray->Get(i)).FromJust();
    }

    miner_t m;
    cl_int ret = initialize_miner(&m, allowedDevices, allowedDevicesArray->Length(), memorySizes, memorySizesArray->Length());

    delete[] allowedDevices;
    delete[] memorySizes;

    if (ret != CL_SUCCESS)
    {
      return Nan::ThrowError(Nan::New("Could not initialize miner.").ToLocalChecked());
    }

    Miner *obj = new Miner(m);
    obj->Wrap(info.This());
    info.GetReturnValue().Set(info.This());
  }

  static NAN_METHOD(GetWorkers)
  {
    Miner *obj = Nan::ObjectWrap::Unwrap<Miner>(info.This());

    v8::Local<v8::Array> workers = Nan::New<v8::Array>(obj->miner.num_workers);
    for (unsigned int i = 0; i < workers->Length(); i++)
    {
      worker_t *w = &obj->miner.workers[i];

      v8::Local<v8::Object> worker = Nan::New<v8::Object>();
      Nan::SetPrivate(worker, Nan::New("worker").ToLocalChecked(), v8::External::New(info.GetIsolate(), w));
      Nan::SetAccessor(worker, Nan::New("deviceName").ToLocalChecked(), GetDeviceName);
      Nan::SetAccessor(worker, Nan::New("deviceVendor").ToLocalChecked(), GetDeviceVendor);
      Nan::SetAccessor(worker, Nan::New("driverVersion").ToLocalChecked(), GetDriverVersion);
      Nan::SetAccessor(worker, Nan::New("maxComputeUnits").ToLocalChecked(), GetMaxComputeUnits);
      Nan::SetAccessor(worker, Nan::New("maxClockFrequency").ToLocalChecked(), GetMaxClockFrequency);
      Nan::SetAccessor(worker, Nan::New("maxMemAllocSize").ToLocalChecked(), GetMaxMemAllocSize);
      Nan::SetAccessor(worker, Nan::New("globalMemSize").ToLocalChecked(), GetGlobalMemSize);
      Nan::SetAccessor(worker, Nan::New("noncesPerRun").ToLocalChecked(), GetNoncesPerRun);
      Nan::SetAccessor(worker, Nan::New("deviceIndex").ToLocalChecked(), GetDeviceIndex);
      Nan::SetMethod(worker, "setup", SetupWorker);
      Nan::SetMethod(worker, "mineNonces", MineNonces);

      workers->Set(i, worker);
    }
    info.GetReturnValue().Set(workers);
  }

  static NAN_GETTER(GetDeviceName)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(Nan::New(worker->device_name).ToLocalChecked());
  }

  static NAN_GETTER(GetDeviceVendor)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(Nan::New(worker->device_vendor).ToLocalChecked());
  }

  static NAN_GETTER(GetDriverVersion)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(Nan::New(worker->driver_version).ToLocalChecked());
  }

  static NAN_GETTER(GetMaxComputeUnits)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(worker->max_compute_units);
  }

  static NAN_GETTER(GetMaxClockFrequency)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(worker->max_clock_frequency);
  }

  static NAN_GETTER(GetMaxMemAllocSize)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set((double)worker->max_mem_alloc_size);
  }

  static NAN_GETTER(GetGlobalMemSize)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set((double)worker->global_mem_size);
  }

  static NAN_GETTER(GetNoncesPerRun)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(worker->nonces_per_run);
  }

  static NAN_GETTER(GetDeviceIndex)
  {
    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    info.GetReturnValue().Set(worker->device_index);
  }

  static NAN_METHOD(SetupWorker)
  {
    v8::Local<v8::Uint8Array> initial_seed = info[0].As<v8::Uint8Array>();
    if (initial_seed->Length() != INITIAL_SEED_SIZE)
    {
      return Nan::ThrowError(Nan::New("Invalid initial seed size.").ToLocalChecked());
    }

    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    cl_int ret = setup_worker(worker, initial_seed->Buffer()->GetContents().Data());
    if (ret != CL_SUCCESS)
    {
      return Nan::ThrowError(Nan::New("setup_worker() failed").ToLocalChecked());
    }
  }

  static NAN_METHOD(MineNonces)
  {
    Nan::Callback *callback = new Nan::Callback(info[0].As<v8::Function>());
    uint32_t start_nonce = Nan::To<uint32_t>(info[1]).FromJust();
    uint32_t share_compact = Nan::To<uint32_t>(info[2]).FromJust();

    v8::Local<v8::Value> ext = Nan::GetPrivate(info.This(), Nan::New("worker").ToLocalChecked()).ToLocalChecked();
    worker_t *worker = (worker_t *)ext.As<v8::External>()->Value();

    Nan::AsyncQueueWorker(new MinerWorker(callback, worker, start_nonce, share_compact));
  }

  static inline Nan::Persistent<v8::Function> &constructor()
  {
    static Nan::Persistent<v8::Function> ctor;
    return ctor;
  }

  miner_t miner;
};

NODE_MODULE(nimiq_miner, Miner::Init);
