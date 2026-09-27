<!-- SPDX-FileCopyrightText: 2026 SANSI GROUP -->
<!-- SPDX-License-Identifier: LicenseRef-Limiar-Private-Use-1.0 -->

# GPU no Limiar: GPU-PV e DDA

Atualizado em 27 de setembro de 2026. Tutorial publico selecionado da
pesquisa de virtualizacao do Limiar. O foco atual e Hyper-V nativo com
OpenHCL e firmware mu_msvm; QEMU permanece uma referencia historica.
Veja o [estado do OpenHCL](OPENHCL-COMPATIBILITY.md).

Este guia explica a preparacao e verificacao de GPU numa VM existente.
Nao e um instalador de OpenHCL e nao fornece firmware, drivers, discos,
perfis privados, credenciais ou os coletores internos do laboratorio.
Os exemplos usam identificadores que cada operador deve obter no seu host.

## Escolher a modalidade

| Modalidade | O que o guest recebe | GPU disponivel ao host | Estado no projeto |
| --- | --- | --- | --- |
| GPU-PV / GPU-P | Acesso paravirtualizado ou particionado | Sim, compartilhada | Demonstrado experimentalmente em Windows com Radeon RX 9070 XT, OpenHCL e firmware personalizado |
| DDA | Um dispositivo PCIe fisico dedicado | Nao, para o dispositivo atribuido | Referencia condicional; nao validado na combinacao OpenHCL/Radeon do lab |

**A mesma GPU nao pode ser dedicada inteira por DDA e permanecer
compartilhada por GPU-PV ao mesmo tempo.** Duas GPUs fisicas permitem
planejar papeis distintos, sujeitos ao suporte da plataforma. Configurar
uma cota de GPU-PV como "100%" nao transforma o compartilhamento em DDA.
Duas entradas DXGI tambem nao significam duas GPUs fisicas.

Firmware, atribuicao de GPU e transporte de imagem sao camadas diferentes.
SMBIOS/ACPI personalizados nao criam suporte a DDA ou IOMMU. Looking Glass
captura a imagem no guest e a apresenta no host; nao atribui a GPU sozinho.
A integracao pretendida pelo Limiar tem capturador no guest e viewer/entrada
no Windows fisico. Ela ainda nao e uma entrega completa, nem tem vantagem
de latencia demonstrada sobre Parsec/Moonlight.

## Suporte e evidencia

- **DDA:** a Microsoft documenta host Windows Server 2016 ou posterior,
  hardware de classe servidor e dispositivos compativeis [1, 2].
- **GPU-P no Server:** requer Windows Server 2025 ou posterior e a matriz
  de GPUs/drivers apropriada [3, 4]. Radeon PRO V710 na lista nao significa
  suporte oficial a RX 9070 XT.
- **Windows cliente:** o troubleshooting da Microsoft exclui os cenarios
  Hyper-V DDA/GPU-P em sistemas cliente e hardware desktop dessa matriz [5].
  Isso nao nega a existencia de GPU-PV em outros usos do Windows, como WSL.
  O funcionamento experimental registrado aqui nao altera a matriz oficial.
- **OpenHCL:** Windows Client/Server tem suporte de desenvolvimento, nao de
  producao, para essas VMs [6]. A existencia de relay VMBus/VPCI ou de um
  cmdlet nao comprova atribuicao de qualquer GPU por esse caminho [7].

O resumo de evidencia local autorizado para publicacao e:

| Verificacao | Resultado e limite |
| --- | --- |
| Combinacao | Windows 11, Hyper-V nativo, OpenHCL em VTL2, firmware personalizado e uma particao GPU-PV coexistiram na mesma VM |
| Driver AMD | Versao 32.0.31041.3013; 133 arquivos esperados do payload conferidos entre host e guest por tamanho e SHA-256 |
| D3D11 anterior | Duas entradas logicas da RX passaram clear/copy/readback: 12.288 pixels cada, 24.576 no total |
| Verificacao desta atualizacao | Leitura de configuracao e hashes; nenhum novo teste de renderizacao, DDA ou alteracao de VM |
| Limites | Nao e prova de Present, OpenGL/Vulkan completos, encoder, latencia, endurance, GPU com relay habilitado ou compatibilidade universal |

Os recibos brutos, identidades de instancia e imagens de firmware permanecem
privados. Esse resultado nao valida um binario gerado a partir da
[referencia neutra publicada](LIMIAR-FIRMWARE-BASE.md), que nao inclui um
build completo de firmware.

## GPU-PV: inventario antes da alteracao

Usar PowerShell 7 x64 elevado no **host**, a partir da raiz do checkout.
Este primeiro bloco apenas consulta; nao cria nem altera uma VM.

```powershell
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V
$repo = (Get-Location).Path
$inventoryScript = Join-Path $repo 'scripts\gpu-pv-inventory.ps1'
if (-not (Test-Path -LiteralPath $inventoryScript -PathType Leaf)) {
    throw 'Execute a partir da raiz do checkout Limiar'
}
$inventory = & $inventoryScript | ConvertFrom-Json
if ($inventory.status -cne 'queried') { throw 'Inventario de GPU indisponivel' }
$inventory.adapters | Select-Object name,driver_version,device_interface
Get-VM | Select-Object Name,Id,State
```

Nao selecionar a primeira placa automaticamente. Obter o GUID e nome da
VM que voce administra e o `device_interface` completo da GPU desejada.
O caminho de interface, possivelmente terminado em `GPUPARAV`, nao e o
`LocationPath` PCIROOT usado por DDA. Manter esse inventario local: ele
pode conter identificadores da maquina.

Preencher os valores do proximo bloco com os resultados locais. Os valores
vazios fazem o exemplo parar por padrao; nao contem uma VM do autor.

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[guid]$vmId = [guid]::Empty
$expectedVmName = 'Limiar-GPU-Example'
$selectedInterface = ''
$expectedDriverVersion = ''
if ($vmId -eq [guid]::Empty -or
    [string]::IsNullOrWhiteSpace($selectedInterface) -or
    [string]::IsNullOrWhiteSpace($expectedDriverVersion)) {
    throw 'Preencha o GUID da VM, a interface exata e a versao do driver'
}

function Get-SelectedVm {
    $target = Get-VM -Id $vmId
    if ($target.Name -cne $expectedVmName) { throw 'O nome da VM nao corresponde ao GUID' }
    $target
}

function Get-SelectedGpu {
    $current = & $inventoryScript | ConvertFrom-Json
    $selected = @($current.adapters | Where-Object {
        $_.device_interface -ieq $selectedInterface
    })
    if ($current.status -cne 'queried' -or $selected.Count -ne 1 -or
        $selected[0].driver_version -cne $expectedDriverVersion) {
        throw 'GPU ausente, ambigua ou com driver diferente do preparado'
    }
    $selected[0]
}

$vm = Get-SelectedVm
$gpu = Get-SelectedGpu
$partitions = @(Get-VMGpuPartitionAdapter -VM $vm)
if ($partitions.Count -eq 1 -and
    $partitions[0].InstancePath -ieq $selectedInterface) {
    'GPU-PV ja anexada: validar o guest, sem anexar novamente.'
} elseif ($partitions.Count -ne 0) {
    throw 'Atribuicao existente diferente: revisar sem remover automaticamente'
}
```

Contagens e cotas brutas devolvidas pelo driver nao sao necessariamente
bytes de VRAM ou porcentagens de desempenho. Por exemplo, valores como
`1000000000` ou o maximo de um inteiro de 64 bits podem representar
convencoes do driver, nao memoria fisica ou capacidade infinita de encoder.
Uma contagem anunciada de 32 nao demonstra 32 VMs uteis. Este guia nao
altera a contagem global de particoes nem define cotas arbitrarias.

## GPU-PV: preparar os drivers completos

Em uma implantacao Server oficialmente suportada, seguir o procedimento de
drivers GPU-P do fabricante [4]. A copia para HostDriverStore descrita aqui
e a tecnica usada no **lab experimental Windows cliente**, nao substitui
essa documentacao de suporte.

1. Na GPU selecionada, resolver o instance ID PnP a partir da interface e
   consultar `DEVPKEY_Device_Service`. O `ImagePath` do servico identifica
   o pacote principal ativo. Nao escolher uma pasta pela data de modificacao.
2. Consultar `DEVPKEY_Device_Driver`, que aponta para a chave ativa em
   `HKLM\SYSTEM\CurrentControlSet\Control\Class`. Na AMD testada, os valores
   `OpenGLVendorName` e `OpenGLVendorNameWow` identificam bibliotecas de um
   pacote OpenGL separado.
3. Resolver os caminhos somente dentro de
   `C:\Windows\System32\DriverStore\FileRepository`. Conferir versao INF,
   proveniencia e assinatura/catalogo. Rejeitar reparse points. Nem todo
   arquivo tem assinatura Authenticode embutida; assinatura por catalogo
   e um mecanismo distinto.
4. Preparar um manifesto de caminhos relativos, tamanhos e SHA-256 de todos
   os arquivos necessarios, preservando subpastas. Excluir apenas os
   logs/ETL/temporarios previstos. Nao montar um pacote misturando versoes.
5. Usar PowerShell Direct autenticado ou uma midia de payload controlada
   para transferir os arquivos ao **guest verificado por UUID**, em
   `C:\Windows\System32\HostDriverStore\FileRepository\<pacote>`.
   Nao compartilhar o DriverStore do host por rede nem instalar um driver
   de guest no host. Rejeitar destinos redirecionados por links.
6. Se uma pasta destino ja existir, comparar primeiro. Conteudo igual nao
   exige copia; divergencia exige manutencao separada, nao sobrescrita em
   massa. Conferir cada arquivo contra o manifesto depois da transferencia.
   Nao prosseguir para anexacao com arquivos ausentes ou divergentes.

O UUID a verificar dentro do guest vem de `Win32_ComputerSystemProduct`;
ele nao deve ser presumido igual ao GUID administrativo de `Get-VM`.
Obter e registrar os dois durante a preparacao da fixture. Usar credenciais
locais protegidas; nunca colocar senha, token ou export de credenciais no
repositorio, num comando publicado ou numa imagem de instalacao distribuida.

### AMD OpenGL e erro 126

No driver AMD testado, o pacote principal `u*.inf_amd64_<id>` tinha os
loaders `atig6pxx.dll`/`atiglpxx.dll`, mas as bibliotecas
`atio6axx.dll`/`atioglxx.dll` pertenciam a `amdogl.inf_amd64_<id>`.
Copiar somente o primeiro pacote deixava essa dependencia ausente.

A correcao local usou o companion indicado pelo registro ativo, da mesma
versao. Foram 128 arquivos de payload principal e cinco do OpenGL; todos
os 133 arquivos esperados foram comparados novamente. O teste de carga
x64/x86 passou de erro 126 a sucesso, sem executar o instalador do pacote.
Isso nao prova renderizacao OpenGL completa nem que toda ocorrencia de
erro 126 tenha essa causa. Esse erro tambem pode indicar outra dependencia
ausente. A contagem e especifica dessa versao, nao uma regra para drivers
futuros. Nao adicionar Vulkan/OpenCL ou outros pacotes por suposicao.

### Limite dos helpers publicados anteriormente

[Prepare-GpuDriver.ps1](../scripts/windows/Prepare-GpuDriver.ps1) prepara
somente o pacote principal. Nao automatiza a descoberta de todos os
companions. [Enable-GpuPv.ps1](../scripts/windows/Enable-GpuPv.ps1) pertence
ao [lab Windows historico](WINDOWS-LAB.md), com seu proprio contrato de
propriedade, um disco e nenhuma rede. Ele tambem altera boot e DVDs.
Nao executar esses helpers diretamente contra uma VM OpenHCL existente
ou editar seus registros para forcar a passagem das verificacoes.

## GPU-PV: anexar uma vez

Antes da alteracao, registrar firmware, configuracao da VM, discos,
particoes e estado grafico do host. Preparar uma copia consistente dos
discos, com desligamento conforme o ciclo de vida da VM; um VHDX copiado
em uso nao e automaticamente um backup consistente. Nao presumir suporte
a checkpoint/save/restore da combinacao OpenHCL/GPU.

Encerrar o trabalho e desligar o guest **normalmente**. Aguardar `Off`, nao
`Saved`. O bloco abaixo requer as variaveis/funcoes anteriores e para por
padrao. Ele e referencia de anexacao, nao um instalador transacional.

```powershell
$preparationVerified = $false
if (-not $preparationVerified) { throw 'Validar payload e backup antes da anexacao' }
$ErrorActionPreference = 'Stop'
$vm = Get-SelectedVm
$gpu = Get-SelectedGpu
if ($vm.State.ToString() -cne 'Off') { throw 'Aguardar desligamento normal da VM' }
if (@(Get-VMGpuPartitionAdapter -VM $vm).Count -ne 0 -or
    @(Get-VMAssignableDevice -VM $vm).Count -ne 0) {
    throw 'A VM ja tem GPU-PV ou DDA; nao alterar automaticamente'
}
$previousMmio = @{
    GuestControlledCacheTypes = $vm.GuestControlledCacheTypes
    LowMemoryMappedIoSpace = $vm.LowMemoryMappedIoSpace
    HighMemoryMappedIoSpace = $vm.HighMemoryMappedIoSpace
}
# Registrar estes valores antes da alteracao, junto ao backup da fixture.
Set-VM -VM $vm -GuestControlledCacheTypes $true `
    -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB
$addedPartition = Add-VMGpuPartitionAdapter -VM $vm `
    -InstancePath $gpu.device_interface -Passthru
if ($addedPartition.InstancePath -ine $gpu.device_interface) {
    Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $addedPartition
    Set-VM -VM $vm @previousMmio
    throw 'A anexacao nao preservou a GPU selecionada'
}
Get-VMGpuPartitionAdapter -VM $vm | Select-Object Id,InstancePath
```

As janelas MMIO de 1/32 GiB sao os valores usados no lab, nao uma formula
universal. Sao espaco de enderecos, nao RAM extra nem VRAM reservada.
Dimensionar conforme a plataforma e o driver. Registrar o ID retornado,
reler configuracao/anexos e iniciar a VM pelo ciclo normal.

**GPU-PV nao exige desmontar a GPU do host.** Nao usar `Disable-PnpDevice`
ou `Dismount-VMHostAssignableDevice` nessa via. Nao alterar Secure Boot,
HVCI, BCD, VBS ou virtualizacao nested como etapa deste tutorial.

Se uma tentativa falhar, manter a fixture desligada, reler as atribuicoes
e remover somente a particao criada naquela tentativa, por ID/objeto.
Restaurar os valores MMIO/cache registrados. Se o comando falhou antes de
retornar um objeto, inspecionar o estado antes de remover qualquer coisa.
Nao retirar uma particao saudavel preexistente nem usar remocao global.

## Validar o guest e preservar o host

Verificar em camadas: uma particao correta no host; identidade do guest;
hashes de drivers; dispositivos PnP sem erros; enumeracao DXGI; pixels;
depois apresentacao, APIs especificas e testes prolongados.

Preparar o [CLI portavel](../scripts/Build-PortableCli.ps1) e copia-lo por
um canal controlado ao guest. Confirmar seu hash. No exemplo abaixo,
`C:\Limiar\limiar.exe` e um caminho de instalacao escolhido pelo operador,
nao um binario fornecido com este tutorial. Executar **dentro do guest**.
Os IDs 1002:7550 selecionam o modelo RX 9070 XT; para outro modelo, usar
os IDs esperados do seu inventario.

```powershell
$ErrorActionPreference = 'Stop'
$exe = 'C:\Limiar\limiar.exe'
$text = & $exe gpu list | Out-String
if ($LASTEXITCODE -ne 0) { throw 'Falha na enumeracao DXGI' }
$inventory = $text | ConvertFrom-Json
$adapters = @($inventory.adapters | Where-Object {
    -not $_.software -and $_.vendor_id -eq 0x1002 -and $_.device_id -eq 0x7550
})
if ($adapters.Count -eq 0) { throw 'GPU esperada nao encontrada por DXGI' }
foreach ($adapter in $adapters) {
    $text = & $exe gpu test --adapter ([string]$adapter.index) --iterations 3 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Falha no teste D3D11' }
    $result = $text | ConvertFrom-Json
    if ($result.status -cne 'passed' -or $result.adapter.software -or
        $result.adapter.luid -cne $adapter.luid -or $result.pixels_verified -ne 12288) {
        throw 'GPU ou pixels nao correspondem ao esperado'
    }
    $result
}
```

O teste verifica clear/copy/readback de uma textura 64x64. Nao mede FPS ou
latencia e nao testa swap-chain Present, encoding, HDR, OpenGL ou Vulkan.
Correlacionar indice e LUID da mesma enumeracao; nao reutilizar indices
antigos apos mudanca de dispositivos. Se houver multiplas GPUs fisicas
iguais, os IDs de modelo sozinhos nao identificam a placa desejada.

No guest, o transporte sintetico pode aparecer como `1414:008e`, com
versao de driver Microsoft em `Win32_VideoController`, enquanto as DLLs
AMD tem a versao do payload. Esse campo isolado nao prova incompatibilidade
de driver. Um adaptador de display virtual de remoting tambem nao e a GPU
fisica. Verificar separadamente renderizacao e topologia de monitores.

Conferir graphics/display do host antes e depois. Ao atualizar o driver
fisico, redescobrir o payload correspondente, planejar manutencao/rollback
e repetir as verificacoes. Nao copiar todo System32 nem misturar DLLs de
versoes diferentes. A comparacao dos arquivos esperados nao e uma auditoria
completa de integridade do guest.

## DDA: requisitos e procedimento condicional

DDA ainda nao foi validado na combinacao OpenHCL/Radeon do Limiar. O fluxo
abaixo e referencia para uma **fixture Hyper-V convencional em Windows
Server**, antes de qualquer integracao OpenHCL. Nao e um recurso pronto
para ativar no atual lab Windows cliente.

1. Confirmar Windows Server suportado, Native PCI Express Control, IOMMU
   (AMD-Vi/VT-d), ACS e GPU/driver compativeis [1, 2]. Dispositivos com
   interrupcoes INTx legadas nao sao suportados. SR-IOV pode habilitar
   capacidades relevantes da plataforma; DDA nao significa necessariamente
   que a propria GPU deva expor funcoes virtuais SR-IOV.
2. Obter uma revisao fixa do
   [SurveyDDA.ps1 oficial](https://github.com/MicrosoftDocs/Virtualization-Documentation/blob/main/hyperv-tools/DiscreteDeviceAssignment/SurveyDDA.ps1),
   revisar o script e registrar seu hash antes de executar no host de teste.
   Conferir o dispositivo exato e seus requisitos MMIO. Um cmdlet presente
   ou `Get-VMHostAssignableDevice` vazio nao substitui o survey.
3. Preparar outra GPU ou caminho de administracao/recuperacao testado para
   o host. Nao desmontar sua unica saida grafica utilizavel. A GPU escolhida
   deve deixar de servir o host, GPU-PV e qualquer outra VM nessa janela.
4. Conferir funcoes PCIe relacionadas, por exemplo audio HDMI, sem atribuir
   automaticamente todas as funcoes ou pontes. Seguir o dominio de
   isolamento e as limitacoes de reset indicados pela plataforma/fabricante.
5. Preparar a VM desligada com RAM fixa e `AutomaticStopAction=TurnOff`.
   Nao depender de save/restore. Calcular MMIO pela soma dos BARs/dispositivos
   e a margem documentada. Exemplos Microsoft de 3 GiB/33280 MiB nao sao
   uma medicao da sua placa [2].
6. Avaliar/instalar a mitigacao de dispositivo fornecida pelo fabricante.
   Desabilitar e desmontar somente a GPU selecionada; atribui-la a VM.
   Dentro do guest, instalar seu driver nativo. A receita HostDriverStore
   de GPU-PV nao substitui essa instalacao.
7. Validar render, apresentacao, estabilidade, reinicios e retorno ao host.
   Depois avaliar separadamente o caminho OpenHCL/VPCI/MMIO/interrupts.
   Nao ligar relay VMBus em uma VM funcional por tentativa.

Exemplo deliberadamente bloqueado por padrao. Preencher somente depois de
concluir os requisitos acima, usando uma fixture sua e uma GPU secundaria.
Nao executar linhas internas isoladamente nem trocar os placeholders por
identificadores de uma maquina de outra pessoa.

```powershell
$ErrorActionPreference = 'Stop'
$ddaPrerequisitesVerified = $false
if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
    throw 'Este fluxo DDA requer host Windows Server suportado'
}
if (-not $ddaPrerequisitesVerified) { throw 'Concluir os requisitos DDA primeiro' }
[guid]$ddaVmId = [guid]::Empty
$ddaVmName = 'Limiar-DDA-Example'
$ddaInstance = ''
$ddaLocation = ''
[uint32]$ddaLowMmio = 0
[uint64]$ddaHighMmio = 0
if ($ddaVmId -eq [guid]::Empty -or $ddaInstance -notlike 'PCI\VEN_*' -or
    $ddaLocation -notlike 'PCIROOT(*)*' -or $ddaLowMmio -eq 0 -or $ddaHighMmio -eq 0) {
    throw 'Preencher GUID, dispositivo exato e MMIO medido'
}
$ddaVm = Get-VM -Id $ddaVmId
if ($ddaVm.Name -cne $ddaVmName -or $ddaVm.State.ToString() -cne 'Off' -or
    (Get-VMMemory -VM $ddaVm).DynamicMemoryEnabled -or
    @(Get-VMGpuPartitionAdapter -VM $ddaVm).Count -ne 0 -or
    @(Get-VMAssignableDevice -VM $ddaVm).Count -ne 0) {
    throw 'Rever identidade e configuracao da fixture DDA'
}
$ddaSettings = @(Get-CimInstance -Namespace root\virtualization\v2 `
    -ClassName Msvm_VirtualSystemSettingData `
    -Filter "VirtualSystemIdentifier='$($ddaVm.Id)' AND VirtualSystemType='Microsoft:Hyper-V:System:Realized'")
if ($ddaSettings.Count -ne 1 -or $ddaSettings[0].GuestStateIsolationType -ne 0) {
    throw 'Exemplo da fixture convencional; OpenHCL exige validacao propria'
}
$ddaPaths = @((Get-PnpDeviceProperty -InstanceId $ddaInstance `
    -KeyName DEVPKEY_Device_LocationPaths).Data)
if ($ddaLocation -notin $ddaPaths) { throw 'LocationPath nao corresponde ao dispositivo' }
# Registrar configuracao original e plano de recuperacao antes destas escritas.
Set-VM -VM $ddaVm -AutomaticStopAction TurnOff -GuestControlledCacheTypes $true `
    -LowMemoryMappedIoSpace $ddaLowMmio -HighMemoryMappedIoSpace $ddaHighMmio
Disable-PnpDevice -InstanceId $ddaInstance -Confirm
if ((Get-PnpDevice -InstanceId $ddaInstance).Problem -ne 'CM_PROB_DISABLED') {
    throw 'Dispositivo nao foi desabilitado; nao desmontar'
}
Dismount-VMHostAssignableDevice -LocationPath $ddaLocation -Confirm
if (@(Get-VMHostAssignableDevice -LocationPath $ddaLocation).Count -ne 1) {
    throw 'Dispositivo nao foi desmontado; nao atribuir'
}
Add-VMAssignableDevice -VM $ddaVm -LocationPath $ddaLocation
Get-VMAssignableDevice -VM $ddaVm -LocationPath $ddaLocation
```

Parar se uma etapa falhar. O exemplo nao usa `-Force` no dismount: essa
opcao pula verificacoes de mitigacao, nao aumenta o isolamento. DDA pode
entregar ao guest capacidades como atualizacao de firmware do dispositivo;
a Microsoft recomenda tenants confiaveis ou mitigacao apropriada [2].
Para conter software potencialmente intrusivo, uma mitigacao ausente e
um requisito nao resolvido, nao uma etapa a ignorar.

### Retornar a GPU ao host

Usar os IDs registrados na tentativa, desligar normalmente a fixture e
conferir o estado antes de cada acao. Nao reutilizar este bloco sem os
registros da atribuicao. Ele tambem para por padrao.

```powershell
$ErrorActionPreference = 'Stop'
$ddaRecoveryVerified = $false
if (-not $ddaRecoveryVerified) { throw 'Conferir o recibo da tentativa DDA antes do retorno' }
$ddaVm = Get-VM -Id $ddaVmId
if ($ddaVm.Name -cne $ddaVmName -or $ddaVm.State.ToString() -cne 'Off') {
    throw 'Identidade divergente ou fixture ainda ligada'
}
$assigned = @(Get-VMAssignableDevice -VM $ddaVm -LocationPath $ddaLocation)
if ($assigned.Count -gt 1) { throw 'Atribuicao ambigua' }
if ($assigned.Count -eq 1) {
    Remove-VMAssignableDevice -VMAssignableDevice $assigned[0] -Confirm
}
$remaining = @(foreach ($candidate in Get-VM) {
    Get-VMAssignableDevice -VM $candidate -LocationPath $ddaLocation
})
if ($remaining.Count -ne 0) { throw 'O dispositivo ainda pertence a uma VM' }
$dismounted = @(Get-VMHostAssignableDevice -LocationPath $ddaLocation)
if ($dismounted.Count -gt 1) { throw 'Dispositivo desmontado ambiguo' }
if ($dismounted.Count -eq 1) {
    Mount-VMHostAssignableDevice -LocationPath $ddaLocation -Confirm
}
if (@(Get-VMHostAssignableDevice -LocationPath $ddaLocation).Count -ne 0) {
    throw 'O dispositivo continua desmontado; nao habilitar'
}
Enable-PnpDevice -InstanceId $ddaInstance -Confirm
```

Restaurar as configuracoes anteriores da fixture pelo registro e verificar
driver/display do host. Se o dismount nao chegou a acontecer, nao inventar
uma atribuicao para desfazer. Uma falha de reset pode exigir recuperacao
planejada; remover e montar nao garante recuperacao sem reiniciar.

## Isolamento e publicacao

GPU-PV preserva um caminho compartilhado pelo driver do host; DDA entrega
mais controle de hardware ao guest. Nenhuma das vias garante ausencia de
vulnerabilidades guest-to-host. Rede, arquivos compartilhados, clipboard,
perifericos e o canal de captura/entrada tambem pertencem ao modelo de
ameacas. A inspiracao no AWS Nitro e arquitetural, nao equivalencia de
seguranca ou desempenho certificada.

Este tutorial nao fornece tecnicas de ocultacao de processos, loaders ou
alteracoes em jogos/anti-cheats. Sucesso de GPU nao demonstra aceitacao
por um aplicativo, e trocar GPU-PV por DDA nao garante resolver uma
rejeicao de VM. Testes de compatibilidade sao separados das verificacoes
de graficos e isolamento.

O texto e os testes originais desta referencia usam a
[licenca Limiar](../LICENSING.md). Direitos anteriores MIT/Apache, GPL do
Looking Glass e direitos da plataforma GitHub permanecem preservados.
Windows, drivers de GPU e imagens geradas nao sao artefatos redistribuiveis
por esta licenca. A [revisao de publicacao](PUBLICATION-REVIEW.md) mantem
firmware, perfis e a pesquisa privada fora deste material selecionado.

## Fontes oficiais

Consultadas em 27/09/2026 pelo MCP oficial da Exa. As paginas Server nao
sao perfeitamente sincronizadas nas listas de GPUs e na redacao sobre
multiplas particoes. Este guia nao amplia suporte combinando afirmacoes
de cenarios diferentes: a evidencia local e de uma unica particao por VM.

1. [Microsoft: Deploy graphics devices using DDA](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/deploy/deploying-graphics-devices-using-dda).
2. [Microsoft: Plan for deploying devices using DDA](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-for-deploying-devices-using-discrete-device-assignment).
3. [Microsoft: GPU partitioning](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/gpu-partitioning).
4. [Microsoft: Partition and assign GPUs to a VM](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/partition-assign-vm-gpu).
5. [Microsoft: GPU assignment, partitioning and passthrough troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/troubleshoot-hyper-v-gpu-assignment-partitioning-passthrough-issues).
6. [OpenVMM: OpenHCL no Hyper-V/Windows](https://openvmm.dev/guide/user_guide/openhcl/run/hyperv.html).
7. [OpenVMM: VMBus relay e interceptacao de dispositivos](https://openvmm.dev/guide/reference/architecture/openhcl/vmbus.html).
8. [Microsoft: PowerShell Direct](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/powershell-direct).

Os exemplos sao verificados por
[testes com providers simulados](../tests/gpu_tutorial.ps1), sem atribuicao
de GPU na CI. Sintaxe e bloqueios testados nao significam DDA validado em
hardware nem certificacao de uma configuracao OpenHCL.
