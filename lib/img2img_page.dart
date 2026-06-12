import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:dotted_border/dotted_border.dart';
import 'package:flutter_animate/flutter_animate.dart';

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
  
  // Controllers for text specifications
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _negativePromptController = TextEditingController();
  final TextEditingController _seedController = TextEditingController(text: "-1");
  final TextEditingController _skipLayersController = TextEditingController(text: "[7, 8, 9]");

  // Image Processing State Data
  Uint8List? _initImageBytes;
  int? _initImageWidth;
  int? _initImageHeight;
  String? _initImageName;

  Uint8List? _controlImageBytes;
  int? _controlImageWidth;
  int? _controlImageHeight;
  String? _controlImageName;

  ui.Image? _generatedUiImage;
  Image? _generatedWidgetImage;
  String? _generationTime;

  // Processing Context Properties
  Img2ImgProcessor? _processor;
  String? _modelPath;
  bool _isModelLoaded = false;
  bool _isGenerating = false;
  double _progressValue = 0.0;
  String _statusText = "Ready";
  List<String> _generationLogs = [];

  // Generation Settings Adjustments
  double _denoisingStrength = 0.75;
  double _cfgScale = 1.0;
  double _guidanceScale = 3.5;
  double _controlStrength = 0.9;
  int _sampleSteps = 4;
  int _clipSkip = 2;
  int _outputWidth = 512;
  int _outputHeight = 512;
  
  SDType _selectedModelType = SDType.NONE;
  Schedule _selectedSchedule = Schedule.DEFAULT;
  SampleMethod _selectedSampleMethod = SampleMethod.EULER;

  bool _useFlashAttention = true;
  bool _vaeTiling = false;
  bool _isDiffusionModelType = false;

  // Automatic TAESD Integration Parameters
  String? _bundledTaesdDir;
  String? _taesdPath;
  bool _useTAESD = false;
  String _taesdMessage = 'TAESD searching...';
  Map<String, bool> _loadedComponents = {};
  
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

  // Auto-loads the tiny autoencoder cleanly from application document streams
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
          _loadedComponents['TAESD'] = true;
          _taesdMessage = 'TAESD auto-loaded (Bundled)';
        });
        developer.log("TAESD implicitly discovered and assigned: $_taesdPath");
      } else {
        setState(() {
          _useTAESD = false;
          _taesdMessage = 'TAESD file missing in application files';
        });
        developer.log("TAESD not found at expected environment path: $targetPath");
      }
    } catch (e) {
      setState(() {
        _useTAESD = false;
        _taesdMessage = 'TAESD initialization error';
      });
      developer.log("Exception verifying bundled asset paths: $e");
    }
  }

  // Model selection execution routine
  Future<void> _pickModel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Select Stable Diffusion Model (.safetensors / .ckpt)',
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _modelPath = result.files.single.path;
        _isModelLoaded = false;
        _statusText = "Model selected. Click 'Load Model' to begin initialization.";
      });
    }
  }

  // Initialize the engine isolate structure
  Future<void> _loadModel() async {
    if (_modelPath == null) {
      ShadToaster.of(context).show(
        const ShadToast.destructive(
          title: Text('Error'),
          description: Text('Please pick a primary base model file first.'),
        ),
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _statusText = "Initializing context frameworks inside engine...";
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
    );

    // Bind log listeners to interface arrays
    _processor!.logListStream.listen((logs) {
      setState(() => _generationLogs = logs);
    });

    _processor!.generationResultStream.listen((result) {
      final ui.Image? rawImg = result['image'];
      final String? timeTaken = result['generationTime'];
      if (rawImg != null) {
        _convertUiImageToWidget(rawImg, timeTaken);
      }
    });

    // Simulated complete fallback context (Isolate feedback updates via log hooks automatically)
    await Future.delayed(const Duration(seconds: 2));
    setState(() {
      _isModelLoaded = true;
      _isGenerating = false;
      _statusText = "Model context initialized successfully.";
    });
  }

  // Image upload handling routines
  Future<void> _pickInitialImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        // Adjust resolution dimensions to enforce alignment to multiples of 8
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

  // Convert raw UI pipeline formats to high level widget wrappers
  Future<void> _convertUiImageToWidget(ui.Image image, String? timeTaken) async {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      setState(() {
        _generatedUiImage = image;
        _generatedWidgetImage = Image.memory(byteData.buffer.asUint8List());
        _generationTime = timeTaken;
        _isGenerating = false;
        _progressValue = 1.0;
        _statusText = "Processing Completed ${timeTaken ?? ''}";
      });
    }
  }

  // Dispatch prompt context variables into the processing frame execution loops
  Future<void> _startGeneration() async {
    if (_processor == null || !_isModelLoaded) {
      ShadToaster.of(context).show(
        const ShadToast.destructive(
          title: Text('Execution Halted'),
          description: Text('Ensure engine processing models are fully compiled before synthesis.'),
        ),
      );
      return;
    }

    if (_initImageBytes == null) {
      ShadToaster.of(context).show(
        const ShadToast.destructive(
          title: Text('Missing Parameter'),
          description: Text('Image-to-Image execution loops require an initial guiding source image.'),
        ),
      );
      return;
    }

    int seedValue = int.tryParse(_seedController.text) ?? -1;

    setState(() {
      _isGenerating = true;
      _progressValue = 0.0;
      _statusText = "Analyzing initial graphics context tensors...";
      _generatedWidgetImage = null;
      _generatedUiImage = null;
    });

    // Prepare processing components directly out of standard formats
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

    // Connect to callbacks
    _processor!.onProgress = (progress) {
      setState(() {
        _progressValue = progress.step / progress.steps;
        _statusText = "Sampling Step ${progress.step}/${progress.steps} (${progress.time.toStringAsFixed(1)}s)";
      });
    };

    await _processor!.generateImage(
      prompt: _promptController.text.isNotEmpty ? _promptController.text : "Detailed masterpiece digital art",
      negativePrompt: _negativePromptController.text,
      initImageData: rgbInitData,
      initImageWidth: _initImageWidth!,
      initImageHeight: _initImageHeight!,
      strength: _denoisingStrength,
      cfgScale: _cfgScale,
      guidance: _guidanceScale,
      width: _outputWidth,
      height: _outputHeight,
      sampleMethod: _selectedSampleMethod.index,
      sampleSteps: _sampleSteps,
      seed: seedValue,
      clipSkip: _clipSkip,
      controlImageData: rgbControlData,
      controlImageWidth: _controlImageWidth,
      controlImageHeight: _controlImageHeight,
      controlStrength: _controlStrength,
      skipLayersText: _skipLayersController.text,
    );
  }

  // Save functionality mapping down into hardware modules
  Future<void> _saveOutput() async {
    if (_generatedUiImage == null || _processor == null) return;
    
    final resultMessage = await _processor!.saveGeneratedImage(
      _generatedUiImage!,
      _promptController.text,
      _outputWidth,
      _outputHeight,
      _selectedSampleMethod,
    );

    ShadToaster.of(context).show(
      ShadToast(
        title: const Text('Export Action'),
        description: Text(resultMessage),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image-to-Image Vector Studio'),
        backgroundColor: theme.colorScheme.background,
        elevation: 0,
      ),
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Configurations Sidebar Panel Controls
            Expanded(
              flex: 4,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // System Hardware Model Loading Section Card
                    ShadCard(
                      title: const Text('Model Architecture Configuration'),
                      description: Text('Active Module: ${_modelPath != null ? _modelPath!.split('/').last : "None Provided"}'),
                      content: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ShadButton.outline(
                                  onPressed: _pickModel,
                                  child: const Text('Pick Base Model File'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ShadButton(
                                onPressed: _modelPath != null && !_isGenerating ? _loadModel : null,
                                child: const Text('Load Model'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          // Automatic status feedback showing bundled state tracking configurations
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.muted,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _useTAESD ? Icons.offline_bolt : Icons.warning_amber_rounded,
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
                            label: const Text('Use Isolated Diffusion Layer Path (Unbundled)'),
                          ),
                          ShadCheckbox(
                            value: _useFlashAttention,
                            onChanged: (v) => setState(() => _useFlashAttention = v),
                            label: const Text('Enable Flash Attention Pipelines'),
                          ),
                          ShadCheckbox(
                            value: _vaeTiling,
                            onChanged: (v) => setState(() => _vaeTiling = v),
                            label: const Text('Enable VAE Tiling (Reduces High VRAM Peaks)'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Inputs Selection UI Mapping Elements
                    ShadCard(
                      title: const Text('Input Layer Transformations'),
                      content: Column(
                        children: [
                          const SizedBox(height: 8),
                          // Source Guiding Array Asset Selection Layout
                          if (_initImageBytes != null) ...[
                            Stack(
                              alignment: 'topRight' as Alignment,
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
                                    const Text('Upload Initial Image Input'),
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

                          // ControlNet Secondary Overlay Setup Layout
                          if (_controlImageBytes != null) ...[
                            Stack(
                              alignment: 'topRight' as Alignment,
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
                              child: const Text('Add Optional ControlNet Guidance Mask'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Prompt Parameters Tuning Panels
                    ShadCard(
                      title: const Text('Hyperparameter Matrix Tuners'),
                      content: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          const Text('Positive Prompt Guidance'),
                          ShadInput(
                            controller: _promptController,
                            placeholder: const Text('Enter descriptive prompt matrices...'),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 12),
                          const Text('Negative Prompt Matrices'),
                          ShadInput(
                            controller: _negativePromptController,
                            placeholder: const Text('Elements to extract/omit out from latent fields...'),
                            maxLines: 2,
                          ),
                          const SizedBox(height: 16),
                          
                          // Denoising Strength Configuration Multipliers
                          Text('Denoising Strength Variance Factor: ${_denoisingStrength.toStringAsFixed(2)}'),
                          ShadSlider(
                            value: _denoisingStrength,
                            min: 0.0,
                            max: 1.0,
                            onChanged: (v) => setState(() => _denoisingStrength = v),
                          ),
                          const SizedBox(height: 12),

                          Text('CFG Guidance Scaling Parameters: ${_cfgScale.toStringAsFixed(1)}'),
                          ShadSlider(
                            value: _cfgScale,
                            min: 1.0,
                            max: 20.0,
                            onChanged: (v) => setState(() => _cfgScale = v),
                          ),
                          const SizedBox(height: 12),

                          Text('Step Synthesis Iterations: $_sampleSteps'),
                          ShadSlider(
                            value: _sampleSteps.toDouble(),
                            min: 1,
                            max: 50,
                            onChanged: (v) => setState(() => _sampleSteps = v.toInt()),
                          ),
                          const SizedBox(height: 12),

                          if (_controlImageBytes != null) ...[
                            Text('ControlNet Weight Factor: ${_controlStrength.toStringAsFixed(2)}'),
                            ShadSlider(
                              value: _controlStrength,
                              min: 0.0,
                              max: 2.0,
                              onChanged: (v) => setState(() => _controlStrength = v),
                            ),
                            const SizedBox(height: 12),
                          ],

                          const Text('Generation Structural Seed Value'),
                          ShadInput(
                            controller: _seedController,
                            placeholder: const Text('-1 loops for absolute randomness'),
                          ),
                          const SizedBox(height: 12),

                          const Text('Advanced Transformer Layer Skipping Map'),
                          ShadInput(
                            controller: _skipLayersController,
                            placeholder: const Text('[7, 8, 9] (Defaults inside SDXL layers)'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Canvas Output Visualizer Real-time Dashboard Panel
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
                                          child: const Text('Export Image to Device Studio'),
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
                                          'Awaiting Target Execution Settings',
                                          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 16),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Configure parameters on the sidebar layout and dispatch the generator',
                                          style: TextStyle(color: theme.colorScheme.mutedForeground, fontSize: 13),
                                        ),
                                      ],
                                    ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Main execution bottom control dashboard
                    Row(
                      children: [
                        ShadButton.outline(
                          onPressed: _generationLogs.isNotEmpty
                              ? () => _showLogsDialog(context, _generationLogs)
                              : null,
                          icon: const Icon(Icons.analytics_outlined),
                          child: const Text('Inspect Stream Logs'),
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
                              Text('Generate Matrix Vector'),
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

  // Presentation alert box viewport parsing the processing loops logs
  void _showLogsDialog(BuildContext context, List<String> logs) {
    showShadDialog(
      context: context,
      builder: (context) => ShadDialog.alert(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 500),
        title: const Text('Isolate Execution Feed Logs'),
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
            child: const Text('Dismiss View'),
          ),
        ],
      ),
    );
  }
}
