import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:dotted_border/dotted_border.dart';

import 'ffi_bindings.dart';
import 'img2img_processor.dart';
import 'utils.dart';
import 'stable_diffusion_service.dart';

class Img2ImgPage extends StatefulWidget {
  const Img2ImgPage({super.key});

  @override
  State<Img2ImgPage> createState() => _Img2ImgPageState();
}

class _Img2ImgPageState extends State<Img2ImgPage> with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  
  // Parameter Input Controllers
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _negativePromptController = TextEditingController();
  final TextEditingController _seedController = TextEditingController(text: "-1");
  final TextEditingController _skipLayersController = TextEditingController(text: "[7, 8, 9]");

  // Image Core State Data
  Uint8List? _initImageBytes;
  int? _initImageWidth;
  int? _initImageHeight;
  String? _initImageName;

  Uint8List? _controlImageBytes;
  int? _controlImageWidth;
  int? _controlImageHeight;
  String? _controlImageName;

  Image? _generatedWidgetImage;
  ui.Image? _generatedUiImage;
  String? _generationTime;

  // Processing Core Infrastructure
  Img2ImgProcessor? _processor;
  String? _modelPath;
  bool _isModelLoaded = false;
  bool _isGenerating = false;
  double _progressValue = 0.0;
  String _statusText = "Ready";
  List<String> _generationLogs = [];

  // Latent Hyperparameters
  double _denoisingStrength = 0.75;
  double _cfgScale = 7.0;
  double _guidanceScale = 3.5;
  double _controlStrength = 0.9;
  int _sampleSteps = 20;
  int _clipSkip = 2;
  int _outputWidth = 512;
  int _outputHeight = 512;
  
  SDType _selectedModelType = SDType.NONE;
  Schedule _selectedSchedule = Schedule.DEFAULT;
  SampleMethod _selectedSampleMethod = SampleMethod.EULER;

  bool _useFlashAttention = true;
  bool _vaeTiling = false;
  bool _isDiffusionModelType = false;

  // Automated TAESD Asset States
  String? _bundledTaesdDir;
  String? _taesdPath;
  bool _useTAESD = false;
  String _taesdMessage = 'Searching for TAESD decoder asset...';
  
  final Map<String, String> _bundledTaesdAssets = {
    'sd1': 'taesd_decoder.safetensors',
  };

  @override
  void initState() {
    super.initState();
    _initBundledTaesd();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _negativePromptController.dispose();
    _seedController.dispose();
    _skipLayersController.dispose();
    _scrollController.dispose();
    _processor?.dispose();
    super.dispose();
  }

  Future<void> _initBundledTaesd() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final assetName = _bundledTaesdAssets['sd1']!;
      final targetPath = '${directory.path}/$assetName';
      
      if (await File(targetPath).exists()) {
        setState(() {
          _bundledTaesdDir = directory.path;
          _taesdPath = targetPath;
          _useTAESD = true;
          _taesdMessage = 'TAESD Auto-Loaded ($assetName)';
        });
        developer.log("TAESD auto-loaded seamlessly from: $_taesdPath");
      } else {
        setState(() {
          _useTAESD = false;
          _taesdMessage = 'TAESD unlinked (Optional file taesd_decoder.safetensors not in Documents)';
        });
        developer.log("TAESD optional path not found at: $targetPath");
      }
    } catch (e) {
      setState(() {
        _useTAESD = false;
        _taesdMessage = 'TAESD status discovery exception';
      });
      developer.log("Exception checking local document spaces: $e");
    }
  }

  Future<void> _pickModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select Base Stable Diffusion Model (.safetensors)',
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _modelPath = result.files.single.path;
        _isModelLoaded = false;
        _statusText = "Model file linked. Direct load required.";
      });
    }
  }

  Future<void> _loadModel() async {
    if (_modelPath == null) {
      ShadToaster.of(context).show(
        const ShadToast.destructive(
          title: Text('Setup Blocked'),
          description: Text('Select a primary base model architecture checkpoint first.'),
        ),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _statusText = "Compiling weights inside generation isolate threads...";
      _generationLogs.clear();
    });

    _processor?.dispose();
    _processor = Img2ImgProcessor(
      modelPath: _modelPath!,
      useFlashAttention: _useFlashAttention,
      modelType: _selectedModelType,
      schedule: _selectedSchedule,
      taesdPath: _useTAESD ? _taesdPath : null,
      useTinyAutoencoder: _useTAESD,
      isDiffusionModelType: _isDiffusionModelType,
      vaeTiling: _vaeTiling,
      clipSkip: _clipSkip,
      onLog: (log) {
        if (mounted) {
          setState(() {
            _generationLogs.add("[Processor Log] ${log.message}");
          });
        }
      },
    );

    _processor!.logListStream.listen((logs) {
      if (mounted) setState(() => _generationLogs = logs);
    });

    _processor!.generationResultStream.listen((result) {
      if (!mounted) return;
      final ui.Image? rawImg = result['image'];
      final String? timeTaken = result['generationTime'];
      if (rawImg != null) {
        _convertUiImageToWidget(rawImg, timeTaken);
      }
    });

    _processor!.loadingStream.listen((isLoading) {
      if (!mounted) return;
      if (!isLoading && !_isModelLoaded) {
        setState(() {
          _isModelLoaded = true;
          _isGenerating = false;
          _statusText = "Model runtime environment loaded completely.";
        });
      }
    });
  }

  Future<void> _pickInitialImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        final processedWidth = (decoded.width ~/ 8) * 8;
        final processedHeight = (decoded.height ~/ 8) * 8;

        setState(() {
          _initImageBytes = bytes;
          _initImageWidth = processedWidth;
          _initImageHeight = processedHeight;
          _initImageName = pickedFile.name;
          _outputWidth = processedWidth;
          _outputHeight = processedHeight;
        });
      }
    }
  }

  Future<void> _pickControlImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        setState(() {
          _controlImageBytes = bytes;
          _controlImageWidth = (decoded.width ~/ 8) * 8;
          _controlImageHeight = (decoded.height ~/ 8) * 8;
          _controlImageName = pickedFile.name;
        });
      }
    }
  }

  Future<void> _convertUiImageToWidget(ui.Image image, String? timeTaken) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      setState(() {
        _generatedUiImage = image;
        _generatedWidgetImage = Image.memory(byteData.buffer.asUint8List());
        _generationTime = timeTaken;
        _isGenerating = false;
        _progressValue = 1.0;
        _statusText = "Synthesized image ready! ${timeTaken ?? ''}";
      });
    }
  }

  Future<void> _startGeneration() async {
    if (_processor == null || !_isModelLoaded) {
      ShadToaster.of(context).show(
        const ShadToast.destructive(
          title: Text('Pipeline Offline'),
          description: Text('Ensure base architecture weights are processed into active context memory.'),
        ),
      );
      return;
    }

    if (_initImageBytes == null) {
      ShadToaster.of(context).show(
        const ShadToast.destructive(
          title: Text('Incomplete Arguments'),
          description: Text('Image-to-Image execution matrices require an active source configuration vector.'),
        ),
      );
      return;
    }

    int seedValue = int.tryParse(_seedController.text) ?? -1;

    setState(() {
      _isGenerating = true;
      _progressValue = 0.0;
      _statusText = "Mapping graphics configurations to sample matrices...";
      _generatedWidgetImage = null;
      _generatedUiImage = null;
    });

    final rawInputImage = img.decodeImage(_initImageBytes!);
    Uint8List rgbInitData = _initImageBytes!;
    if (rawInputImage != null) {
      rgbInitData = Uint8List.fromList(img.encodeJpg(rawInputImage));
    }

    Uint8List? rgbControlData;
    if (_controlImageBytes != null) {
      final rawControlImage = img.decodeImage(_controlImageBytes!);
      if (rawControlImage != null) {
        rgbControlData = Uint8List.fromList(img.encodeJpg(rawControlImage));
      }
    }

    StableDiffusionService.progressStream.listen((progress) {
      if (mounted && _isGenerating) {
        setState(() {
          _progressValue = progress.step / _sampleSteps;
          _statusText = "Iterative Sampling Matrix: Step ${progress.step}/$_sampleSteps";
        });
      }
    });

    // Invoking updated method signature with correct named parameters
    await _processor!.generateImg2Img(
      inputImageData: rgbInitData,
      inputWidth: _initImageWidth!,
      inputHeight: _initImageHeight!,
      channel: 3, // Standard RGB
      outputWidth: _outputWidth,
      outputHeight: _outputHeight,
      prompt: _promptController.text.isNotEmpty ? _promptController.text : "Masterpiece hyperrealistic digital canvas style",
      negativePrompt: _negativePromptController.text,
      clipSkip: _clipSkip,
      cfgScale: _cfgScale,
      guidance: _guidanceScale,
      sampleMethod: _selectedSampleMethod.index,
      sampleSteps: _sampleSteps,
      strength: _denoisingStrength,
      seed: seedValue,
      controlImageData: rgbControlData,
      controlImageWidth: _controlImageWidth,
      controlImageHeight: _controlImageHeight,
      controlStrength: _controlStrength,
      skipLayersText: _skipLayersController.text,
    );
  }

  Future<void> _saveOutput() async {
    if (_generatedUiImage == null || _processor == null) return;
    
    final msgStr = await _processor!.saveGeneratedImage(
      _generatedUiImage!,
      _promptController.text,
      _outputWidth,
      _outputHeight,
      _selectedSampleMethod,
    );

    ShadToaster.of(context).show(
      ShadToast(
        title: const Text('Export Subsystem'),
        description: Text(msgStr),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image-to-Image Latent Processing Desk'),
        backgroundColor: theme.colorScheme.background,
        elevation: 0,
      ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sidebar Parameters Tuning Workspace
            Expanded(
              flex: 4,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShadCard(
                      title: const Text('Model Architecture Configuration'),
                      description: Text('Active Module: ${_modelPath != null ? _modelPath!.split('/').last : "None Mounted"}'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ShadButton.outline(
                                  onPressed: _pickModel,
                                  child: const Text('Link Model Weights'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ShadButton(
                                onPressed: _modelPath != null && !_isGenerating ? _loadModel : null,
                                child: const Text('Initialize Context'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.muted,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _useTAESD ? Icons.offline_bolt : Icons.info_outline,
                                  color: _useTAESD ? Colors.green : Colors.amber,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _taesdMessage,
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          ShadCheckbox(
                            value: _isDiffusionModelType,
                            onChanged: (v) => setState(() => _isDiffusionModelType = v),
                            label: const Text('Use Isolated Diffusion Pipeline Paths'),
                          ),
                          ShadCheckbox(
                            value: _useFlashAttention,
                            onChanged: (v) => setState(() => _useFlashAttention = v),
                            label: const Text('Enable Flash Attention Pipelines'),
                          ),
                          ShadCheckbox(
                            value: _vaeTiling,
                            onChanged: (v) => setState(() => _vaeTiling = v),
                            label: const Text('Enable VAE Tiling (Optimizes Heavy Memory Load peaks)'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    ShadCard(
                      title: const Text('Source Transformations Workspace'),
                      child: Column(
                        children: [
                          const SizedBox(height: 8),
                          if (_initImageBytes != null) ...[
                            Stack(
                              alignment: Alignment.topRight,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(_initImageBytes!, height: 180, fit: BoxFit.cover),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.cancel, color: Colors.red),
                                  onPressed: () => setState(() {
                                    _initImageBytes = null;
                                    _initImageName = null;
                                  }),
                                )
                              ],
                            ),
                          ] else ...[
                            DottedBorder(
                              color: theme.colorScheme.border,
                              borderType: BorderType.RRect,
                              radius: const Radius.circular(8),
                              child: Container(
                                height: 120,
                                width: double.infinity,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Text('Upload Priming Transform Vector'),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        ShadButton.outline(
                                          onPressed: () => _pickInitialImage(ImageSource.gallery),
                                          size: ShadButtonSize.sm,
                                          child: const Text('Gallery'),
                                        ),
                                        const SizedBox(width: 8),
                                        ShadButton.outline(
                                          onPressed: () => _pickInitialImage(ImageSource.camera),
                                          size: ShadButtonSize.sm,
                                          child: const Text('Camera'),
                                        ),
                                      ],
                                    )
                                  ],
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (_controlImageBytes != null) ...[
                            Stack(
                              alignment: Alignment.topRight,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(_controlImageBytes!, height: 140, fit: BoxFit.cover),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.cancel, color: Colors.red),
                                  onPressed: () => setState(() {
                                    _controlImageBytes = null;
                                    _controlImageName = null;
                                  }),
                                )
                              ],
                            ),
                          ] else ...[
                            ShadButton.outline(
                              onPressed: _pickControlImage,
                              width: double.infinity,
                              child: const Text('Link Auxiliary ControlNet Image Mask'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    ShadCard(
                      title: const Text('Matrix Prompt Hyperparameters'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          const Text('Positive Conditioning Guidance'),
                          ShadInput(
                            controller: _promptController,
                            placeholder: const Text('Input descriptive canvas prompts...'),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 12),
                          const Text('Negative Disruption Modifiers'),
                          ShadInput(
                            controller: _negativePromptController,
                            placeholder: const Text('Elements to avoid during generation matrices...'),
                            maxLines: 2,
                          ),
                          const SizedBox(height: 16),
                          
                          Text('Denoising Transform Strength Factor: ${_denoisingStrength.toStringAsFixed(2)}'),
                          Slider.adaptive(
                            value: _denoisingStrength,
                            min: 0.0,
                            max: 1.0,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (v) => setState(() => _denoisingStrength = v),
                          ),
                          const SizedBox(height: 12),

                          Text('CFG Tensor Scaling Matrix: ${_cfgScale.toStringAsFixed(1)}'),
                          Slider.adaptive(
                            value: _cfgScale,
                            min: 1.0,
                            max: 20.0,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (v) => setState(() => _cfgScale = v),
                          ),
                          const SizedBox(height: 12),

                          Text('Total Processing Iterative Steps: $_sampleSteps'),
                          Slider.adaptive(
                            value: _sampleSteps.toDouble(),
                            min: 1,
                            max: 50,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (v) => setState(() => _sampleSteps = v.toInt()),
                          ),
                          const SizedBox(height: 12),

                          if (_controlImageBytes != null) ...[
                            Text('ControlNet Extraction Weight: ${_controlStrength.toStringAsFixed(2)}'),
                            Slider.adaptive(
                              value: _controlStrength,
                              min: 0.0,
                              max: 2.0,
                              activeColor: theme.colorScheme.primary,
                              onChanged: (v) => setState(() => _controlStrength = v),
                            ),
                            const SizedBox(height: 12),
                          ],

                          const Text('Structural Synthesis Seed'),
                          ShadInput(
                            controller: _seedController,
                            placeholder: const Text('-1 loops random numerical maps'),
                          ),
                          const SizedBox(height: 12),

                          const Text('Transformer Layer Skipping Configuration'),
                          ShadInput(
                            controller: _skipLayersController,
                            placeholder: const Text('[7, 8, 9] (Common across heavy SDXL structures)'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Canvas Output Dashboard Viewer Workspace
            VerticalDivider(width: 1, color: theme.colorScheme.border),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.muted.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: theme.colorScheme.border),
                        ),
                        child: Center(
                          child: _generatedWidgetImage != null
                              ? Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: InteractiveViewer(
                                          child: _generatedWidgetImage!,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        ShadButton(
                                          onPressed: _saveOutput,
                                          icon: const Icon(Icons.save_alt, size: 16),
                                          child: const Text('Export Output Matrix to Gallery'),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                )
                              : _isGenerating
                                  ? Padding(
                                      padding: const EdgeInsets.all(24.0),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          const CircularProgressIndicator(),
                                          const SizedBox(height: 20),
                                          LinearProgressIndicator(
                                            value: _progressValue,
                                            backgroundColor: theme.colorScheme.border,
                                            color: theme.colorScheme.primary,
                                          ),
                                          const SizedBox(height: 12),
                                          Text(_statusText, style: const TextStyle(fontWeight: FontWeight.w600)),
                                        ],
                                      ),
                                    )
                                  : Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.brush_outlined, size: 64, color: theme.colorScheme.border),
                                        const SizedBox(height: 16),
                                        const Text(
                                          'Awaiting Operational Constraints Map',
                                          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Mount required layers from the side panel configuration tools to dispatch structural updates.',
                                          style: TextStyle(color: theme.colorScheme.mutedForeground, fontSize: 13),
                                        ),
                                      ],
                                    ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        ShadButton.outline(
                          onPressed: _generationLogs.isNotEmpty
                              ? () => _showLogsDialog(context, _generationLogs)
                              : null,
                          icon: const Icon(Icons.analytics_outlined),
                          child: const Text('Inspect Run Logs'),
                        ),
                        const Spacer(),
                        ShadButton(
                          onPressed: !_isGenerating && _isModelLoaded && _initImageBytes != null
                              ? _startGeneration
                              : null,
                          size: ShadButtonSize.lg,
                          child: Row(
                            children: const [
                              Icon(Icons.bolt, size: 18),
                              SizedBox(width: 6),
                              Text('Synthesize Target Matrix'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLogsDialog(BuildContext context, List<String> logs) {
    showShadDialog(
      context: context,
      builder: (context) => ShadDialog.alert(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 500),
        title: const Text('Isolate Execution Output Logs'),
        description: SizedBox(
          height: 320,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6.0),
              child: SelectableText(
                logs.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Dismiss Monitor View'),
          ),
        ],
      ),
    );
  }
}
